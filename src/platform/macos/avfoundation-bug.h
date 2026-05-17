/**
 * @file src/platform/macos/avfoundation-bug.h
 * @brief Workarounds for AVFoundation capture bugs on macOS.
 */
#pragma once

// standard includes
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Notes mouse movement so an armed AVFoundation cursor reset can run.
void avf_bug_note_mouse_activity(void);

// Notes keyboard input so the cursor reset only runs after text-entry-shaped input.
void avf_bug_note_keyboard_activity(void);

// Enables or disables the workaround while AVFoundation capture is active.
void avf_bug_set_active(bool active);

#ifdef __cplusplus
}  // extern "C"
#endif
