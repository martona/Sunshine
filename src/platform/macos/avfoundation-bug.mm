/**
 * @file src/platform/macos/avfoundation-bug.mm
 * @brief Workarounds for AVFoundation capture bugs on macOS.
 */

// local includes
#include "src/platform/macos/avfoundation-bug.h"

#include "src/logging.h"

// standard includes
#include <string_view>

// platform includes
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

using namespace std::literals;

namespace {
  constexpr int64_t CURSOR_VISIBILITY_RESET_DELAY_NS = NSEC_PER_SEC;
  constexpr CGFloat DOCK_POKE_MARGIN = 8.0;

  dispatch_queue_t cursor_reset_queue() {
    static dispatch_once_t once;
    static dispatch_queue_t queue;
    dispatch_once(&once, ^{
      queue = dispatch_queue_create("avfoundationCursorResetQueue", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
  }

  uint64_t cursor_reset_generation {};
  bool cursor_reset_scheduled {};
  bool cursor_reset_armed {};
  bool is_active {};

  bool dock_process_id(pid_t &pid) {
    NSArray<NSRunningApplication *> *dock_apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"];
    if (dock_apps.count == 0) {
      return false;
    }

    pid = dock_apps.firstObject.processIdentifier;
    return true;
  }

  bool ax_element_frame(AXUIElementRef element, CGRect &frame) {
    CFTypeRef position_value = nullptr;
    CFTypeRef size_value = nullptr;

    if (AXUIElementCopyAttributeValue(element, kAXPositionAttribute, &position_value) != kAXErrorSuccess || !position_value) {
      return false;
    }

    if (AXUIElementCopyAttributeValue(element, kAXSizeAttribute, &size_value) != kAXErrorSuccess || !size_value) {
      CFRelease(position_value);
      return false;
    }

    CGPoint position = CGPointZero;
    CGSize size = CGSizeZero;
    bool ok = AXValueGetValue((AXValueRef) position_value, (AXValueType) kAXValueCGPointType, &position) &&
              AXValueGetValue((AXValueRef) size_value, (AXValueType) kAXValueCGSizeType, &size);

    CFRelease(position_value);
    CFRelease(size_value);

    if (!ok) {
      return false;
    }

    frame = CGRectMake(position.x, position.y, size.width, size.height);
    return !CGRectIsEmpty(frame);
  }

  bool ax_element_role_is(AXUIElementRef element, CFStringRef expected_role) {
    CFTypeRef role = nullptr;
    if (AXUIElementCopyAttributeValue(element, kAXRoleAttribute, &role) != kAXErrorSuccess || !role) {
      return false;
    }

    bool matches = CFGetTypeID(role) == CFStringGetTypeID() &&
                   CFStringCompare((CFStringRef) role, expected_role, 0) == kCFCompareEqualTo;
    CFRelease(role);
    return matches;
  }

  bool ax_element_is_hidden(AXUIElementRef element) {
    CFTypeRef hidden = nullptr;
    if (AXUIElementCopyAttributeValue(element, kAXHiddenAttribute, &hidden) != kAXErrorSuccess || !hidden) {
      return false;
    }

    bool result = CFGetTypeID(hidden) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef) hidden);
    CFRelease(hidden);
    return result;
  }

  bool search_dock_ax_frame(AXUIElementRef element, CGRect &frame, int depth) {
    if (depth > 8 || ax_element_is_hidden(element)) {
      return false;
    }

    if (ax_element_role_is(element, CFSTR("AXList"))) {
      CGRect list_frame = CGRectZero;
      if (ax_element_frame(element, list_frame)) {
        frame = list_frame;
        return true;
      }
    }

    CFTypeRef children_value = nullptr;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children_value) != kAXErrorSuccess || !children_value) {
      return false;
    }

    bool found = false;
    if (CFGetTypeID(children_value) == CFArrayGetTypeID()) {
      CFArrayRef children = (CFArrayRef) children_value;
      CFIndex count = CFArrayGetCount(children);
      for (CFIndex i = 0; i < count; ++i) {
        AXUIElementRef child = (AXUIElementRef) CFArrayGetValueAtIndex(children, i);
        if (child && search_dock_ax_frame(child, frame, depth + 1)) {
          found = true;
          break;
        }
      }
    }

    CFRelease(children_value);
    return found;
  }

  bool dock_frame_from_accessibility(CGRect &frame) {
    pid_t dock_pid = 0;
    if (!dock_process_id(dock_pid)) {
      return false;
    }

    AXUIElementRef dock = AXUIElementCreateApplication(dock_pid);
    if (!dock) {
      return false;
    }

    bool found = search_dock_ax_frame(dock, frame, 0);
    CFRelease(dock);

    return found;
  }

  bool dock_edge_poke_point(CGPoint original, CGPoint &point) {
    CGRect bounds = CGRectZero;
    if (!dock_frame_from_accessibility(bounds)) {
      return false;
    }

    if (bounds.size.width >= bounds.size.height) {
      CGFloat x = original.x < CGRectGetMidX(bounds) ? CGRectGetMinX(bounds) + DOCK_POKE_MARGIN : CGRectGetMaxX(bounds) - DOCK_POKE_MARGIN;
      point = CGPointMake(x, CGRectGetMidY(bounds));
    } else {
      CGFloat y = original.y < CGRectGetMidY(bounds) ? CGRectGetMinY(bounds) + DOCK_POKE_MARGIN : CGRectGetMaxY(bounds) - DOCK_POKE_MARGIN;
      point = CGPointMake(CGRectGetMidX(bounds), y);
    }

    return true;
  }

  void post_mouse_move(CGEventSourceRef source, CGPoint point) {
    CGEventRef event = CGEventCreateMouseEvent(source, kCGEventMouseMoved, point, kCGMouseButtonLeft);
    if (event) {
      CGEventPost(kCGHIDEventTap, event);
      CFRelease(event);
      CGWarpMouseCursorPosition(point);
    }
  }

  void reset_cursor_visibility() {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    bool cursor_visible = CGCursorIsVisible();
#pragma clang diagnostic pop

    if (is_active && !cursor_visible) {
      CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
      if (source) {
        CGEventRef snapshot = CGEventCreate(source);
        if (snapshot) {
          CGPoint original = CGEventGetLocation(snapshot);
          CFRelease(snapshot);

          CGPoint poke_point = CGPointZero;
          if (dock_edge_poke_point(original, poke_point)) {
            BOOST_LOG(debug) << "AVFoundation cursor visibility reset: moving cursor to Dock and back"sv;
            post_mouse_move(source, poke_point);
            post_mouse_move(source, original);
          }
        }
        CFRelease(source);
      }
    }
  }

  void schedule_cursor_visibility_reset_check(uint64_t generation) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, CURSOR_VISIBILITY_RESET_DELAY_NS), cursor_reset_queue(), ^{
      if (generation != cursor_reset_generation) {
        if (cursor_reset_scheduled) {
          schedule_cursor_visibility_reset_check(cursor_reset_generation);
        }
        return;
      }

      cursor_reset_scheduled = false;
      cursor_reset_armed = is_active;
    });
  }
}  // namespace

void avf_bug_note_mouse_activity() {
  dispatch_async(cursor_reset_queue(), ^{
    if (!is_active) {
      return;
    }

    ++cursor_reset_generation;
    if (cursor_reset_armed) {
      cursor_reset_armed = false;
      reset_cursor_visibility();
    }

    if (cursor_reset_scheduled) {
      return;
    }

    cursor_reset_scheduled = true;
    schedule_cursor_visibility_reset_check(cursor_reset_generation);
  });
}

void avf_bug_set_active(bool active) {
  dispatch_sync(cursor_reset_queue(), ^{
    ++cursor_reset_generation;
    cursor_reset_scheduled = false;
    cursor_reset_armed = false;

    is_active = active;
  });
}
