#ifndef RUNNER_LOCAL_IMPORT_BRIDGE_H_
#define RUNNER_LOCAL_IMPORT_BRIDGE_H_

#include <windows.h>

namespace flutter { class FlutterEngine; }

// Wire once after FlutterWindow has created its Flutter engine. Forward the
// window's MessageHandler message tuple through HandleLocalImportMessage.
void AttachLocalImportBridge(flutter::FlutterEngine* engine, HWND window);
void DetachLocalImportBridge();
bool HandleLocalImportMessage(HWND window, UINT message, WPARAM wparam, LPARAM lparam);

// If the command line contains local TXT/EPUB paths, forward them to the live
// MgRead window. Returns true only after that window acknowledges the bounded
// WM_COPYDATA request; false means the caller should continue cold startup.
bool TryForwardLocalImportArguments();

#endif  // RUNNER_LOCAL_IMPORT_BRIDGE_H_
