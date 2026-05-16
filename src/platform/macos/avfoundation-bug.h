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

void avf_bug_note_mouse_activity(void);
void avf_bug_set_active(bool active);

#ifdef __cplusplus
}  // extern "C"
#endif
