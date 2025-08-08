/*
 * AutoRaise - Copyright (C) 2025 sbmpost
 * Some pieces of the code are based on
 * metamove by jmgao as part of XFree86
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

// g++ -O2 -Wall -fobjc-arc -D"NS_FORMAT_ARGUMENT(A)=" -o AutoRaise AutoRaise.mm \
//   -framework AppKit && ./AutoRaise

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>
#include <AppKit/AppKit.h>
#include <Carbon/Carbon.h>
#include <libproc.h>
#include <QuartzCore/QuartzCore.h>
#include <unistd.h>

#define AUTORAISE_VERSION "5.4"
#define STACK_THRESHOLD 20

#ifdef EXPERIMENTAL_FOCUS_FIRST
#if SKYLIGHT_AVAILABLE
// Focus first is an experimental feature that can break easily across different OSX
// versions. It relies on the private Skylight api. As such, there are absolutely no
// guarantees that this feature will keep on working in future versions of AutoRaise.
#define FOCUS_FIRST
#else
#pragma message "Skylight api is unavailable, Focus First is disabled"
#endif
#endif

// It seems OSX Monterey introduced a transparent 3 pixel border around each window. This
// means that when two windows are visually precisely connected and not overlapping, in
// reality they are. Consequently one has to move the mouse 3 pixels further out of the
// visual area to make the connected window raise. This new OSX 'feature' also introduces
// unwanted raising of windows when visually connected to the top menu bar. To solve this
// we correct the mouse position before determining which window is underneath the mouse.
#define WINDOW_CORRECTION 3
#define MENUBAR_CORRECTION 8
static CGPoint oldCorrectedPoint = {0, 0};

// An activate delay of about 10 microseconds is just high enough to ensure we always
// find the latest focused (main)window. This value should be kept as low as possible.
#define ACTIVATE_DELAY_MS 10

#define SCALE_DELAY_MS 400 // The moment the mouse scaling should start, feel free to modify.
#define SCALE_DURATION_MS (SCALE_DELAY_MS+600) // Mouse scale duration, feel free to modify.

#ifdef FOCUS_FIRST
#define kCPSUserGenerated 0x200
extern "C" CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);
extern "C" CGError _SLPSSetFrontProcessWithOptions(
  ProcessSerialNumber *psn, uint32_t wid, uint32_t mode);

/* -----------Could these be a replacement for GetProcessForPID?-----------
extern "C" int SLSMainConnectionID(void);
extern "C" CGError SLSGetWindowOwner(int cid, uint32_t wid, int *wcid);
extern "C" CGError SLSGetConnectionPSN(int cid, ProcessSerialNumber *psn);
int element_connection;
SLSGetWindowOwner(SLSMainConnectionID(), window_id, &element_connection);
SLSGetConnectionPSN(element_connection, &window_psn);
-------------------------------------------------------------------------*/
#endif

typedef int CGSConnectionID;
extern "C" CGSConnectionID CGSMainConnectionID(void);
extern "C" CGError CGSSetCursorScale(CGSConnectionID connectionId, float scale);
extern "C" CGError CGSGetCursorScale(CGSConnectionID connectionId, float *scale);
extern "C" AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *out);
// Above methods are undocumented and subjective to incompatible changes

#ifdef FOCUS_FIRST
static int raiseDelayCount = 0;
static pid_t lastFocusedWindow_pid;
static AXUIElementRef _lastFocusedWindow = NULL;
#endif

CFMachPortRef eventTap = NULL;
static char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
static bool activated_by_task_switcher = false;
static bool waitingForWindowChange = false;
static AXObserverRef windowObserver = NULL;
static AXUIElementRef _accessibility_object = AXUIElementCreateSystemWide();
static AXUIElementRef _previousFinderWindow = NULL;
static AXUIElementRef _dock_app = NULL;
static NSArray * ignoreApps = NULL;
static NSArray * ignoreTitles = NULL;
static NSArray * stayFocusedBundleIds = NULL;
static NSArray * const mainWindowAppsWithoutTitle =@[
    @"System Settings",
    @"System Information",
    @"Photos",
    @"Calculator",
    @"Podcasts",
    @"Stickies Pro",
    @"Reeder"
];
static NSArray * chromiumBrowsers = @[
    @"Chrome",
    @"Chromium",
    @"Vivaldi",
    @"Brave",
    @"Opera",
    @"Edge"
];
static NSString * const DockBundleId = @"com.apple.dock";
static NSString * const FinderBundleId = @"com.apple.finder";
static NSString * const LittleSnitchBundleId = @"at.obdev.littlesnitch";
static NSString * const AssistiveControl = @"AssistiveControl";
static NSString * const MissionControl = @"Mission Control";
static NSString * const BartenderBar = @"Bartender Bar";
static NSString * const AppStoreSearchResults = @"Search results";
static NSString * const Untitled = @"Untitled"; // OSX Email search
static NSString * const Zim = @"Zim";
static NSString * const XQuartz = @"XQuartz";
static NSString * const Finder = @"Finder";
static NSString * const NoTitle = @"";
static CGPoint desktopOrigin = {0, 0};
static CGPoint oldPoint = {0, 0};
static bool propagateMouseMoved = false;
static bool ignoreSpaceChanged = false;
static bool invertIgnoreApps = false;
static bool spaceHasChanged = false;
static bool appWasActivated = false;
static bool altTaskSwitcher = false;
static bool warpMouse = false;
static bool verbose = false;
static bool focusOnDemand = true;
static float warpX = 0.5;
static float warpY = 0.5;
static float oldScale = 1;
static float cursorScale = 2;
static float mouseDelta = 0;
static int ignoreTimes = 0;
static int raiseTimes = 0;
static int delayTicks = 0;
static int delayCount = 0;
static int pollMillis = 0;
static int disableKey = 0;
static bool shouldFocusOnDemand = true;

static AXUIElementRef lastHighlightedWindow = NULL;
static AXUIElementRef pendingFocusWindow = NULL; // window pending focus when highlighted
static CGWindowID currentFocusedWindowID = 0; // track focused window id for comparisons

//----------------------------------------yabai focus only methods------------------------------------------

#ifdef FOCUS_FIRST
// The two methods below, starting with "window_manager" were copied from
// https://github.com/koekeishiya/yabai and slightly modified. See also:
// https://github.com/Hammerspoon/hammerspoon/issues/370#issuecomment-545545468
void window_manager_make_key_window(ProcessSerialNumber * _window_psn, uint32_t window_id) {
    uint8_t * bytes = (uint8_t *) malloc(0xf8);
    memset(bytes, 0, 0xf8);

    bytes[0x04] = 0xf8;
    bytes[0x3a] = 0x10;

    memcpy(bytes + 0x3c, &window_id, sizeof(uint32_t));
    memset(bytes + 0x20, 0xFF, 0x10);

    bytes[0x08] = 0x01;
    SLPSPostEventRecordTo(_window_psn, bytes);

    bytes[0x08] = 0x02;
    SLPSPostEventRecordTo(_window_psn, bytes);
    free(bytes);
}

void window_manager_focus_window_without_raise(
    ProcessSerialNumber * _window_psn, uint32_t window_id,
    ProcessSerialNumber * _focused_window_psn, uint32_t focused_window_id
) {
    if (verbose) { NSLog(@"Focus"); }
    if (_focused_window_psn) {
        Boolean same_process;
        SameProcess(_window_psn, _focused_window_psn, &same_process);
        if (same_process) {
            if (verbose) { NSLog(@"Same process"); }
            uint8_t * bytes = (uint8_t *) malloc(0xf8);
            memset(bytes, 0, 0xf8);
            bytes[0x04] = 0xf8;
            bytes[0x08] = 0x0d;

            bytes[0x8a] = 0x02;
            memcpy(bytes + 0x3c, &focused_window_id, sizeof(uint32_t));
            SLPSPostEventRecordTo(_focused_window_psn, bytes);

            // @hack
            // Artificially delay the activation by 1ms. This is necessary
            // because some applications appear to be confused if both of
            // the events appear instantaneously.
            usleep(10000);

            bytes[0x8a] = 0x01;
            memcpy(bytes + 0x3c, &window_id, sizeof(uint32_t));
            SLPSPostEventRecordTo(_window_psn, bytes);
            free(bytes);
        }
    }

    _SLPSSetFrontProcessWithOptions(_window_psn, window_id, kCPSUserGenerated);
    window_manager_make_key_window(_window_psn, window_id);
}
#endif

//---------------------------------------------helper methods-----------------------------------------------

inline void activate(pid_t pid) {
    if (verbose) { NSLog(@"Activate"); }
#ifdef OLD_ACTIVATION_METHOD
    ProcessSerialNumber process;
    OSStatus error = GetProcessForPID(pid, &process);
    if (!error) { SetFrontProcessWithOptions(&process, kSetFrontProcessFrontWindowOnly); }
#else
    // Note activateWithOptions does not work properly on OSX 11.1
    [NSRunningApplication runningApplicationWithProcessIdentifier: pid];
#endif
}

inline void raiseAndActivate(AXUIElementRef _window, pid_t window_pid) {
    if (verbose) { NSLog(@"Raise"); }
    if (AXUIElementPerformAction(_window, kAXRaiseAction) == kAXErrorSuccess) {
        activate(window_pid);
        // Update our tracked focused window id if possible
        CGWindowID wid = 0;
        if (_AXUIElementGetWindow(_window, &wid) == kAXErrorSuccess) {
            currentFocusedWindowID = wid;
            if (verbose) { NSLog(@"Updated currentFocusedWindowID to %u", wid); }
        }
    }
}

inline void logWindowTitle(NSString * prefix, AXUIElementRef _window) {
    CFStringRef _windowTitle = NULL;
    AXUIElementCopyAttributeValue(_window, kAXTitleAttribute, (CFTypeRef *) &_windowTitle);
    if (_windowTitle) {
        NSLog(@"%@: `%@`", prefix, _windowTitle);
        CFRelease(_windowTitle);
    } else {
        pid_t pid;
        NSString * _appName = NULL;
        if (AXUIElementGetPid(_window, &pid) == kAXErrorSuccess) {
            _appName = [NSRunningApplication runningApplicationWithProcessIdentifier: pid].localizedName;
        }
        if (_appName) { NSLog(@"%@ (app name): `%@`", prefix, _appName); }
        else { NSLog(@"%@: null", prefix); }
    }
}

// TODO: does not take into account different languages
inline bool titleEquals(AXUIElementRef _element, NSArray * _titles, NSArray * _patterns = NULL, bool logTitle = false) {
    bool equal = false;
    CFStringRef _elementTitle = NULL;
    AXUIElementCopyAttributeValue(_element, kAXTitleAttribute, (CFTypeRef *) &_elementTitle);
    if (logTitle) { NSLog(@"element title: `%@`", _elementTitle); }
    if (_elementTitle) {
        NSString * _title = (__bridge NSString *) _elementTitle;
        equal = [_titles containsObject: _title];
        if (!equal && _patterns) {
            for (NSString * _pattern in _patterns) {
                equal = [_title rangeOfString: _pattern options: NSRegularExpressionSearch].location != NSNotFound;
                if (equal) { break; }
            }
        }
        CFRelease(_elementTitle);
    } else { equal = [_titles containsObject: NoTitle]; }
    return equal;
}

inline bool dock_active() {
    bool active = false;
    AXUIElementRef _focusedUIElement = NULL;
    AXUIElementCopyAttributeValue(_dock_app, kAXFocusedUIElementAttribute, (CFTypeRef *) &_focusedUIElement);
    if (_focusedUIElement) {
        active = true;
        if (verbose) { NSLog(@"Dock is active"); }
        CFRelease(_focusedUIElement);
    }
    return active;
}

inline bool mc_active() {
    bool active = false;
    CFArrayRef _children = NULL;
    AXUIElementCopyAttributeValue(_dock_app, kAXChildrenAttribute, (CFTypeRef *) &_children);
    if (_children) {
        CFIndex count = CFArrayGetCount(_children);
        for (CFIndex i=0;!active && i != count;i++) {
            CFStringRef _element_role = NULL;
            AXUIElementRef _element = (AXUIElementRef) CFArrayGetValueAtIndex(_children, i);
            AXUIElementCopyAttributeValue(_element, kAXRoleAttribute, (CFTypeRef *) &_element_role);
            if (_element_role) {
                active = CFEqual(_element_role, kAXGroupRole) && titleEquals(_element, @[MissionControl]);
                CFRelease(_element_role);
            }
        }
        CFRelease(_children);
    }

    if (verbose && active) { NSLog(@"Mission Control is active"); }
    return active;
}

NSDictionary * topwindow(CGPoint point) {
    NSDictionary * top_window = NULL;
    NSArray * window_list = (NSArray *) CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID));

    pid_t our_pid = [[NSProcessInfo processInfo] processIdentifier];

    for (NSDictionary * window in window_list) {
        NSDictionary * window_bounds_dict = window[(NSString *) CFBridgingRelease(kCGWindowBounds)];

        if (![window[(__bridge id) kCGWindowLayer] isEqual: @0]) { continue; }
        
        // Skip our own highlight window
        pid_t window_pid = [window[(__bridge id) kCGWindowOwnerPID] intValue];
        if (window_pid == our_pid) { continue; }

        NSRect window_bounds = NSMakeRect(
            [window_bounds_dict[@"X"] intValue],
            [window_bounds_dict[@"Y"] intValue],
            [window_bounds_dict[@"Width"] intValue],
            [window_bounds_dict[@"Height"] intValue]);

        if (NSPointInRect(NSPointFromCGPoint(point), window_bounds)) {
            top_window = window;
            break;
        }
    }

    return top_window;
}

AXUIElementRef fallback(CGPoint point) {
    if (verbose) { NSLog(@"Fallback"); }
    AXUIElementRef _window = NULL;
    NSDictionary * top_window = topwindow(point);
    if (top_window) {
        CFTypeRef _windows_cf = NULL;
        pid_t pid = [top_window[(__bridge id) kCGWindowOwnerPID] intValue];
        AXUIElementRef _window_owner = AXUIElementCreateApplication(pid);
        AXUIElementCopyAttributeValue(_window_owner, kAXWindowsAttribute, &_windows_cf);
        CFRelease(_window_owner);
        if (_windows_cf) {
            NSArray * application_windows = (NSArray *) CFBridgingRelease(_windows_cf);
            CGWindowID top_window_id = [top_window[(__bridge id) kCGWindowNumber] intValue];
            if (top_window_id) {
                for (id application_window in application_windows) {
                    CGWindowID application_window_id;
                    AXUIElementRef application_window_ax =
                        (__bridge AXUIElementRef) application_window;
                    if (_AXUIElementGetWindow(
                        application_window_ax,
                        &application_window_id) == kAXErrorSuccess) {
                        if (application_window_id == top_window_id) {
                            _window = application_window_ax;
                            CFRetain(_window);
                            break;
                        }
                    }
                }
            }
        } else {
            activate(pid);
        }
    }

    return _window;
}

AXUIElementRef get_raisable_window(AXUIElementRef _element, CGPoint point, int count) {
    AXUIElementRef _window = NULL;
    if (_element) {
        if (count >= STACK_THRESHOLD) {
            if (verbose) {
                NSLog(@"Stack threshold reached");
                pid_t application_pid;
                if (AXUIElementGetPid(_element, &application_pid) == kAXErrorSuccess) {
                    proc_pidpath(application_pid, pathBuffer, sizeof(pathBuffer));
                    NSLog(@"Application path: %s", pathBuffer);
                }
            }
            CFRelease(_element);
        } else {
            CFStringRef _element_role = NULL;
            AXUIElementCopyAttributeValue(_element, kAXRoleAttribute, (CFTypeRef *) &_element_role);
            bool check_attributes = !_element_role;
            if (_element_role) {
                if (CFEqual(_element_role, kAXDockItemRole) ||
                    CFEqual(_element_role, kAXMenuItemRole) ||
                    CFEqual(_element_role, kAXMenuRole) ||
                    CFEqual(_element_role, kAXMenuBarRole) ||
                    CFEqual(_element_role, kAXMenuBarItemRole)) {
                    CFRelease(_element_role);
                    CFRelease(_element);
                } else if (
                    CFEqual(_element_role, kAXWindowRole) ||
                    CFEqual(_element_role, kAXSheetRole) ||
                    CFEqual(_element_role, kAXDrawerRole)) {
                    CFRelease(_element_role);
                    _window = _element;
                } else if (CFEqual(_element_role, kAXApplicationRole)) {
                    CFRelease(_element_role);
                    if (titleEquals(_element, @[XQuartz])) {
                        pid_t application_pid;
                        if (AXUIElementGetPid(_element, &application_pid) == kAXErrorSuccess) {
                            pid_t frontmost_pid = [[[NSWorkspace sharedWorkspace]
                                frontmostApplication] processIdentifier];
                            if (application_pid != frontmost_pid) {
                                // Focus and/or raising is the responsibility of XQuartz.
                                // As such AutoRaise features (delay/warp) do not apply.
                                activate(application_pid);
                            }
                        }
                        CFRelease(_element);
                    } else { check_attributes = true; }
                } else {
                    CFRelease(_element_role);
                    check_attributes = true;
                }
            }

            if (check_attributes) {
                AXUIElementCopyAttributeValue(_element, kAXParentAttribute, (CFTypeRef *) &_window);
                bool no_parent = !_window;
                _window = get_raisable_window(_window, point, ++count);
                if (!_window) {
                    AXUIElementCopyAttributeValue(_element, kAXWindowAttribute, (CFTypeRef *) &_window);
                    if (!_window && no_parent) { _window = fallback(point); }
                }
                CFRelease(_element);
            }
        }
    }

    return _window;
}

AXUIElementRef get_mousewindow(CGPoint point) {
    AXUIElementRef _element = NULL;
    AXError error = AXUIElementCopyElementAtPosition(_accessibility_object, point.x, point.y, &_element);

    AXUIElementRef _window = NULL;
    if (_element) {
        // Check if this element belongs to our own process (highlight window)
        pid_t element_pid;
        if (AXUIElementGetPid(_element, &element_pid) == kAXErrorSuccess) {
            pid_t our_pid = [[NSProcessInfo processInfo] processIdentifier];
            if (element_pid == our_pid) {
                // This is our highlight window, use fallback to find the window underneath
                CFRelease(_element);
                _window = fallback(point);
            } else {
                _window = get_raisable_window(_element, point, 0);
            }
        } else {
            _window = get_raisable_window(_element, point, 0);
        }
    } else if (error == kAXErrorCannotComplete || error == kAXErrorNotImplemented) {
        // fallback, happens for apps that do not support the Accessibility API
        if (verbose) { NSLog(@"Copy element: no accessibility support"); }
        _window = fallback(point);
    } else if (error == kAXErrorIllegalArgument) {
        // fallback, happens for Progressive Web Apps (PWAs)
        if (verbose) { NSLog(@"Copy element: illegal argument"); }
        _window = fallback(point);
    } else if (error == kAXErrorNoValue) {
        // fallback, happens sometimes when switching to another app (with cmd-tab)
        if (verbose) { NSLog(@"Copy element: no value"); }
        _window = fallback(point);
    } else if (error == kAXErrorAttributeUnsupported) {
        // no fallback, happens when hovering into volume/WiFi menubar window
        if (verbose) { NSLog(@"Copy element: attribute unsupported"); }
    } else if (error == kAXErrorFailure) {
        // no fallback, happens when hovering over the menubar itself
        if (verbose) { NSLog(@"Copy element: failure"); }
    } else if (verbose) {
        NSLog(@"Copy element: AXError %d", error);
    }

    if (verbose) {
        if (_window) { logWindowTitle(@"Mouse window", _window); }
        else { NSLog(@"No raisable window"); }
    }

    return _window;
}

CGPoint get_mousepoint(AXUIElementRef _window) {
    CGPoint mousepoint = {0, 0};
    AXValueRef _size = NULL;
    AXValueRef _pos = NULL;
    AXUIElementCopyAttributeValue(_window, kAXSizeAttribute, (CFTypeRef *) &_size);
    if (_size) {
        AXUIElementCopyAttributeValue(_window, kAXPositionAttribute, (CFTypeRef *) &_pos);
        if (_pos) {
            CGSize cg_size;
            CGPoint cg_pos;
            if (AXValueGetValue(_size, kAXValueTypeCGSize, &cg_size) &&
                AXValueGetValue(_pos, kAXValueTypeCGPoint, &cg_pos)) {
                mousepoint.x = cg_pos.x + (cg_size.width * warpX);
                mousepoint.y = cg_pos.y + (cg_size.height * warpY);
            }
            CFRelease(_pos);
        }
        CFRelease(_size);
    }

    return mousepoint;
}

bool contained_within(AXUIElementRef _window1, AXUIElementRef _window2) {
    bool contained = false;
    AXValueRef _size1 = NULL;
    AXValueRef _size2 = NULL;
    AXValueRef _pos1 = NULL;
    AXValueRef _pos2 = NULL;

    AXUIElementCopyAttributeValue(_window1, kAXSizeAttribute, (CFTypeRef *) &_size1);
    if (_size1) {
        AXUIElementCopyAttributeValue(_window1, kAXPositionAttribute, (CFTypeRef *) &_pos1);
        if (_pos1) {
            AXUIElementCopyAttributeValue(_window2, kAXSizeAttribute, (CFTypeRef *) &_size2);
            if (_size2) {
                AXUIElementCopyAttributeValue(_window2, kAXPositionAttribute, (CFTypeRef *) &_pos2);
                if (_pos2) {
                    CGSize cg_size1;
                    CGSize cg_size2;
                    CGPoint cg_pos1;
                    CGPoint cg_pos2;
                    if (AXValueGetValue(_size1, kAXValueTypeCGSize, &cg_size1) &&
                        AXValueGetValue(_pos1, kAXValueTypeCGPoint, &cg_pos1) &&
                        AXValueGetValue(_size2, kAXValueTypeCGSize, &cg_size2) &&
                        AXValueGetValue(_pos2, kAXValueTypeCGPoint, &cg_pos2)) {
                        contained = cg_pos1.x > cg_pos2.x && cg_pos1.y > cg_pos2.y &&
                            cg_pos1.x + cg_size1.width < cg_pos2.x + cg_size2.width &&
                            cg_pos1.y + cg_size1.height < cg_pos2.y + cg_size2.height;
                    }
                    CFRelease(_pos2);
                }
                CFRelease(_size2);
            }
            CFRelease(_pos1);
        }
        CFRelease(_size1);
    }

    return contained;
}

void findDockApplication() {
    NSArray * _apps = [[NSWorkspace sharedWorkspace] runningApplications];
    for (NSRunningApplication * app in _apps) {
        if ([app.bundleIdentifier isEqual: DockBundleId]) {
            _dock_app = AXUIElementCreateApplication(app.processIdentifier);
            break;
        }
    }

    if (verbose && !_dock_app) { NSLog(@"Dock application isn't running"); }
}

void findDesktopOrigin() {
    NSScreen * main_screen = NSScreen.screens[0];
    float mainScreenTop = NSMaxY(main_screen.frame);
    for (NSScreen * screen in [NSScreen screens]) {
        float screenOriginY = mainScreenTop - NSMaxY(screen.frame);
        if (screenOriginY < desktopOrigin.y) { desktopOrigin.y = screenOriginY; }
        if (screen.frame.origin.x < desktopOrigin.x) { desktopOrigin.x = screen.frame.origin.x; }
    }

    if (verbose) { NSLog(@"Desktop origin (%f, %f)", desktopOrigin.x, desktopOrigin.y); }
}

inline NSScreen * findScreen(CGPoint point) {
    NSScreen * main_screen = NSScreen.screens[0];
    point.y = NSMaxY(main_screen.frame) - point.y;
    for (NSScreen * screen in [NSScreen screens]) {
        NSRect screen_bounds = NSMakeRect(
            screen.frame.origin.x,
            screen.frame.origin.y,
            NSWidth(screen.frame) + 1,
            NSHeight(screen.frame) + 1
        );
        if (NSPointInRect(NSPointFromCGPoint(point), screen_bounds)) {
            return screen;
        }
    }
    return NULL;
}

inline bool is_desktop_window(AXUIElementRef _window) {
    bool desktop_window = false;
    AXValueRef _pos = NULL;
    AXUIElementCopyAttributeValue(_window, kAXPositionAttribute, (CFTypeRef *) &_pos);
    if (_pos) {
        CGPoint cg_pos;
        desktop_window = AXValueGetValue(_pos, kAXValueTypeCGPoint, &cg_pos) &&
            NSEqualPoints(NSPointFromCGPoint(cg_pos), NSPointFromCGPoint(desktopOrigin));
        CFRelease(_pos);
    }

    if (verbose && desktop_window) { NSLog(@"Desktop window"); }
    return desktop_window;
}

inline bool is_full_screen(AXUIElementRef _window) {
    bool full_screen = false;
    AXValueRef _pos = NULL;
    AXUIElementCopyAttributeValue(_window, kAXPositionAttribute, (CFTypeRef *) &_pos);
    if (_pos) {
        CGPoint cg_pos;
        if (AXValueGetValue(_pos, kAXValueTypeCGPoint, &cg_pos)) {
            NSScreen * screen = findScreen(cg_pos);
            if (screen) {
                AXValueRef _size = NULL;
                AXUIElementCopyAttributeValue(_window, kAXSizeAttribute, (CFTypeRef *) &_size);
                if (_size) {
                    CGSize cg_size;
                    if (AXValueGetValue(_size, kAXValueTypeCGSize, &cg_size)) {
                        float menuBarHeight =
                            fmax(0, NSMaxY(screen.frame) - NSMaxY(screen.visibleFrame) - 1);
                        NSScreen * main_screen = NSScreen.screens[0];
                        float screenOriginY = NSMaxY(main_screen.frame) - NSMaxY(screen.frame);
                        full_screen = cg_pos.x == NSMinX(screen.frame) &&
                                      cg_pos.y == screenOriginY + menuBarHeight &&
                                      cg_size.width == NSWidth(screen.frame) &&
                                      cg_size.height == NSHeight(screen.frame) - menuBarHeight;
                    }
                    CFRelease(_size);
                }
            }
        }
        CFRelease(_pos);
    }

    if (verbose && full_screen) { NSLog(@"Full screen window"); }
    return full_screen;
}

inline bool is_main_window(AXUIElementRef _app, AXUIElementRef _window, bool chrome_app) {
    bool main_window = false;
    CFBooleanRef _result = NULL;
    AXUIElementCopyAttributeValue(_window, kAXMainAttribute, (CFTypeRef *) &_result);
    if (_result) {
        main_window = CFEqual(_result, kCFBooleanTrue);
        if (main_window) {
            CFStringRef _element_sub_role = NULL;
            AXUIElementCopyAttributeValue(_window, kAXSubroleAttribute, (CFTypeRef *) &_element_sub_role);
            if (_element_sub_role) {
                main_window = !CFEqual(_element_sub_role, kAXDialogSubrole);
                if (verbose && !main_window) { NSLog(@"Dialog window"); }
                CFRelease(_element_sub_role);
            }
        }
        CFRelease(_result);
    }

    bool finder_app = titleEquals(_app, @[Finder]);
    main_window = main_window && (chrome_app || finder_app ||
        !titleEquals(_window, @[NoTitle]) ||
        titleEquals(_app, mainWindowAppsWithoutTitle));

    main_window = main_window || (!finder_app && is_full_screen(_window));

    if (verbose && !main_window) { NSLog(@"Not a main window"); }
    return main_window;
}

inline bool is_chrome_app(NSString * bundleIdentifier) {
    NSArray * components = [bundleIdentifier componentsSeparatedByString: @"."];
    return components.count > 4 &&
           [chromiumBrowsers containsObject: components[2]] &&
           [components[3] isEqual: @"app"];
}

//---------------------------------------------highlight overlay methods------------------------------------------

// Forward declarations
void clearHighlight();
void clearHighlightVisual();
void createHighlightWindow(CGRect windowBounds, CGWindowID targetWindowID);

// Global highlight window
static NSWindow* highlightWindow = nil;
static dispatch_source_t highlightTimer = nil;

void createHighlightWindow(CGRect windowBounds, CGWindowID targetWindowID) {
    // Clear any existing visual highlight
    clearHighlightVisual();
    
    // Convert from Accessibility coordinates (top-left origin) to Cocoa coordinates (bottom-left origin)
    // Find the primary screen (the one at origin 0,0) - this is what the Accessibility API uses as reference
    NSScreen *primaryScreen = nil;
    for (NSScreen *screen in [NSScreen screens]) {
        if (NSEqualPoints(screen.frame.origin, NSZeroPoint)) {
            primaryScreen = screen;
            break;
        }
    }
    
    if (!primaryScreen) {
        // Fallback to first screen if we can't find one at origin 0,0
        primaryScreen = [NSScreen screens].firstObject;
    }
    
    CGFloat primaryScreenHeight = primaryScreen.frame.size.height;
    
    // Debug: Log screen information
    if (verbose) {
        NSScreen *mainScreen = [NSScreen mainScreen];
        NSLog(@"Primary screen (for coordinates): %@ (%.0f x %.0f)", 
              primaryScreen.localizedName ?: @"Unknown",
              primaryScreen.frame.size.width, primaryScreen.frame.size.height);
        NSLog(@"Main screen (has focus): %@ (%.0f x %.0f) at origin (%.0f, %.0f)", 
              mainScreen.localizedName ?: @"Unknown",
              mainScreen.frame.size.width, mainScreen.frame.size.height,
              mainScreen.frame.origin.x, mainScreen.frame.origin.y);
        NSLog(@"Window bounds from AX API: (%.0f, %.0f) size (%.0f x %.0f)",
              windowBounds.origin.x, windowBounds.origin.y,
              windowBounds.size.width, windowBounds.size.height);
    }
    
    // Convert Y coordinate using primary screen height
    CGFloat convertedY = primaryScreenHeight - (windowBounds.origin.y + windowBounds.size.height);
    NSRect frameRect = NSMakeRect(windowBounds.origin.x, convertedY, 
                                  windowBounds.size.width, windowBounds.size.height);
    
    // Create window in main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            // Create a borderless window
            highlightWindow = [[NSWindow alloc] initWithContentRect:frameRect
                                                          styleMask:NSWindowStyleMaskBorderless
                                                            backing:NSBackingStoreBuffered
                                                              defer:NO];
            
            // Create a custom view with border instead of filled background
            NSView *contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frameRect.size.width, frameRect.size.height)];
            [contentView setWantsLayer:YES];
            
            // Create border effect
            CALayer *layer = [contentView layer];
            [layer setBackgroundColor:[[NSColor colorWithWhite:1.0 alpha:0.05] CGColor]];
            [layer setBorderColor:[[NSColor clearColor] CGColor]];
            [layer setBorderWidth:3.0];
            [layer setCornerRadius:8.0];
            
            [highlightWindow setContentView:contentView];
            [highlightWindow setBackgroundColor:[NSColor clearColor]];
            [highlightWindow setOpaque:NO];
            [highlightWindow setHasShadow:NO];
            [highlightWindow setIgnoresMouseEvents:YES];
            
            // Don't use a fixed window level - we'll position it relative to the target window
            [highlightWindow setLevel:NSNormalWindowLevel];
            [highlightWindow setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces | 
                                                  NSWindowCollectionBehaviorStationary |
                                                  NSWindowCollectionBehaviorIgnoresCycle |
                                                  NSWindowCollectionBehaviorFullScreenAuxiliary];
            
            // Start with window invisible
            [highlightWindow setAlphaValue:0.0];
            
            // Order the highlight window just above the target window
            [highlightWindow orderWindow:NSWindowAbove relativeTo:(NSInteger)targetWindowID];
            
            // Fade in over 100ms
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = 0.10;
                [[highlightWindow animator] setAlphaValue:1.0];
            } completionHandler:^{
                // Then fade out over 200ms
                [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                    context.duration = 0.2;
                    [[highlightWindow animator] setAlphaValue:0.0];
                } completionHandler:^{
                    clearHighlightVisual();
                }];
            }];
            
            if (verbose) { 
                NSLog(@"Created highlight window at (%.0f, %.0f) size (%.0f, %.0f) above window ID %d", 
                      frameRect.origin.x, frameRect.origin.y, 
                      frameRect.size.width, frameRect.size.height,
                      targetWindowID); 
            }
        }
    });
}

void clearHighlightVisual() {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            if (highlightTimer) {
                dispatch_source_cancel(highlightTimer);
                highlightTimer = nil;
            }
            
            if (highlightWindow) {
                [highlightWindow orderOut:nil];
                highlightWindow = nil;
                if (verbose) { NSLog(@"Cleared highlight window visual"); }
            }
        }
    });
}

void clearHighlight() {
    clearHighlightVisual();
    
    if (lastHighlightedWindow) {
        CFRelease(lastHighlightedWindow);
        lastHighlightedWindow = NULL;
    }

    if (pendingFocusWindow) {
        CFRelease(pendingFocusWindow);
        pendingFocusWindow = NULL;
    }
}

void showHighlightForWindow(AXUIElementRef _window) {
    if (!_window) {
        // Only clear if we had a highlighted window before
        if (lastHighlightedWindow) {
            clearHighlight();
        }
        return;
    }
    
    // Don't show highlight when Mission Control is active
    if (mc_active()) {
        clearHighlight();
        return;
    }
    
    // Check if this is a different window than last time
    bool isDifferentWindow = true;
    CGWindowID currentWindowID = 0;
    if (lastHighlightedWindow) {
        CGWindowID lastWindowID;
        if (_AXUIElementGetWindow(_window, &currentWindowID) == kAXErrorSuccess &&
            _AXUIElementGetWindow(lastHighlightedWindow, &lastWindowID) == kAXErrorSuccess) {
            isDifferentWindow = (currentWindowID != lastWindowID);
        }
    } else {
        // Get the window ID for the first time
        _AXUIElementGetWindow(_window, &currentWindowID);
    }
    
    // Show highlight only when entering a new window
    if (isDifferentWindow && currentWindowID != 0) {
        // Update last highlighted window
        if (lastHighlightedWindow) {
            CFRelease(lastHighlightedWindow);
        }
        lastHighlightedWindow = _window;
        CFRetain(lastHighlightedWindow);

        // Set pending focus only if this window isn't already the focused window
        CGWindowID targetWindowID = 0;
        if (_AXUIElementGetWindow(_window, &targetWindowID) == kAXErrorSuccess) {
            if (targetWindowID != currentFocusedWindowID) {
                if (pendingFocusWindow) { CFRelease(pendingFocusWindow); pendingFocusWindow = NULL; }
                pendingFocusWindow = _window;
                CFRetain(pendingFocusWindow);
                if (verbose) { NSLog(@"Pending focus window set to %u", targetWindowID); }
            } else {
                // If the window under the cursor is already focused, clear any pending focus
                if (pendingFocusWindow) { CFRelease(pendingFocusWindow); pendingFocusWindow = NULL; }
                if (verbose) { NSLog(@"Window under cursor is already focused (%u), no pending focus set", targetWindowID); }
            }
        }
        
        // Get window bounds
        AXValueRef _size = NULL;
        AXValueRef _pos = NULL;
        
        if (AXUIElementCopyAttributeValue(_window, kAXSizeAttribute, (CFTypeRef *) &_size) == kAXErrorSuccess &&
            AXUIElementCopyAttributeValue(_window, kAXPositionAttribute, (CFTypeRef *) &_pos) == kAXErrorSuccess) {
            
            CGSize cg_size;
            CGPoint cg_pos;
            if (AXValueGetValue(_size, kAXValueTypeCGSize, &cg_size) &&
                AXValueGetValue(_pos, kAXValueTypeCGPoint, &cg_pos)) {
                
                CGRect windowBounds = CGRectMake(cg_pos.x, cg_pos.y, cg_size.width, cg_size.height);
                createHighlightWindow(windowBounds, currentWindowID);
            }
            
            if (_size) CFRelease(_size);
            if (_pos) CFRelease(_pos);
        }
        
        if (verbose) {
            logWindowTitle(@"Highlighting window", _window);
        }
    }
}

//---------------------------------------------focus-on-demand methods------------------------------------------

CGPoint applyCorrectionToPoint(CGPoint mousePoint) {
    if (@available(macOS 12.00, *)) {
        // Apply same correction logic as in onTick() for macOS Monterey+ window borders
        NSScreen * screen = findScreen(mousePoint);
        if (screen) {
            NSScreen * main_screen = NSScreen.screens[0];
            float screenOriginX = NSMinX(screen.frame) - NSMinX(main_screen.frame);
            float screenOriginY = NSMaxY(main_screen.frame) - NSMaxY(screen.frame);

            if (mousePoint.x > screenOriginX + NSWidth(screen.frame) - WINDOW_CORRECTION) {
                mousePoint.x = screenOriginX + NSWidth(screen.frame) - 1;
            } else if (mousePoint.x < screenOriginX + WINDOW_CORRECTION - 1) {
                mousePoint.x = screenOriginX + 1;
            }

            if (mousePoint.y > screenOriginY + NSHeight(screen.frame) - WINDOW_CORRECTION) {
                mousePoint.y = screenOriginY + NSHeight(screen.frame) - 1;
            } else {
                float menuBarHeight = fmax(0, NSMaxY(screen.frame) - NSMaxY(screen.visibleFrame) - 1);
                if (mousePoint.y < screenOriginY + menuBarHeight + MENUBAR_CORRECTION) {
                    mousePoint.y = screenOriginY;
                }
            }
        }
    }
    return mousePoint;
}

bool shouldFocusWindow(AXUIElementRef _window, pid_t window_pid) {
    if (!_window) return false;
    
    bool needs_raise = !invertIgnoreApps;
    AXUIElementRef _windowApp = AXUIElementCreateApplication(window_pid);
    
    if (needs_raise && titleEquals(_window, @[NoTitle, Untitled])) {
        needs_raise = is_main_window(_windowApp, _window, is_chrome_app(
            [NSRunningApplication runningApplicationWithProcessIdentifier: window_pid].bundleIdentifier));
        if (verbose && !needs_raise) { NSLog(@"Excluding window"); }
    } else if (needs_raise &&
        titleEquals(_window, @[BartenderBar, Zim, AppStoreSearchResults], ignoreTitles)) {
        needs_raise = false;
        if (verbose) { NSLog(@"Excluding window"); }
    } else {
        if (titleEquals(_windowApp, ignoreApps)) {
            needs_raise = invertIgnoreApps;
            if (verbose) {
                if (invertIgnoreApps) {
                    NSLog(@"Including app");
                } else {
                    NSLog(@"Excluding app");
                }
            }
        }
    }
    
    CFRelease(_windowApp);
    return needs_raise;
}

void handleFocusOnDemand(CGEventType type, CGEventRef event) {
    if (verbose) { NSLog(@"Focus-on-demand triggered"); }

    // Don't handle focus-on-demand when Mission Control is active
    if (mc_active()) {
        if (verbose) { NSLog(@"Mission Control active, skipping focus-on-demand"); }
        return;
    }

    // Only handle explicit key down or mouse button down events
    if (!(type == kCGEventKeyDown || type == kCGEventLeftMouseDown ||
          type == kCGEventRightMouseDown || type == kCGEventOtherMouseDown)) {
        if (verbose) { NSLog(@"Non-actionable event for focus-on-demand, ignoring"); }
        return;
    }

    // If we don't have a pending focus window from highlighting, ignore
    if (!pendingFocusWindow) {
        if (verbose) { NSLog(@"No pending focus window, ignoring input"); }
        return;
    }

    // Get mouse position from the event
    CGPoint mousePoint = CGEventGetLocation(event);
    mousePoint = applyCorrectionToPoint(mousePoint);

    // Find window under cursor
    AXUIElementRef _targetWindow = get_mousewindow(mousePoint);
    if (!_targetWindow) {
        if (verbose) { NSLog(@"No window under cursor on input, ignoring"); }
        return;
    }

    // Compare pendingFocusWindow with the current target under cursor
    CGWindowID pendingID = 0;
    CGWindowID targetID = 0;
    if (_AXUIElementGetWindow(pendingFocusWindow, &pendingID) != kAXErrorSuccess ||
        _AXUIElementGetWindow(_targetWindow, &targetID) != kAXErrorSuccess) {
        if (verbose) { NSLog(@"Unable to resolve window ids for pending/target, ignoring"); }
        CFRelease(_targetWindow);
        return;
    }

    // If pending differs from actual window under cursor, ignore
    if (pendingID != targetID) {
        if (verbose) { NSLog(@"Pending window (%u) differs from cursor window (%u), ignoring", pendingID, targetID); }
        CFRelease(_targetWindow);
        return;
    }

    // If the pending window is already the focused window, clear pending and ignore
    if (pendingID == currentFocusedWindowID) {
        if (verbose) { NSLog(@"Pending window %u is already focused, clearing pending", pendingID); }
        CFRelease(_targetWindow);
        CFRelease(pendingFocusWindow);
        pendingFocusWindow = NULL;
        return;
    }

    // Finally, perform the focus/raise
    if (verbose) { NSLog(@"Focus-on-demand: focusing pending window %u", pendingID); }

    // Clear highlight and pending before focusing to avoid race conditions
    clearHighlight();
    if (pendingFocusWindow) { CFRelease(pendingFocusWindow); pendingFocusWindow = NULL; }

    pid_t targetWindow_pid;
    if (AXUIElementGetPid(_targetWindow, &targetWindow_pid) == kAXErrorSuccess) {
        raiseAndActivate(_targetWindow, targetWindow_pid);
        // Small delay to ensure focus completes before input reaches application
        usleep(1000); // 1ms
    } else if (verbose) {
        NSLog(@"Unable to get pid for target window");
    }

    CFRelease(_targetWindow);
}

//-----------------------------------------------notifications----------------------------------------------

void spaceChanged();
bool appActivated();
void onTick();

@interface MDWorkspaceWatcher:NSObject {}
- (id)init;
@end

static MDWorkspaceWatcher * workspaceWatcher = NULL;

@implementation MDWorkspaceWatcher
- (id)init {
    if ((self = [super init])) {
        NSNotificationCenter * center =
            [[NSWorkspace sharedWorkspace] notificationCenter];
        [center
            addObserver: self
            selector: @selector(spaceChanged:)
            name: NSWorkspaceActiveSpaceDidChangeNotification
            object: nil];
        if (warpMouse) {
            [center
                addObserver: self
                selector: @selector(appActivated:)
                name: NSWorkspaceDidActivateApplicationNotification
                object: nil];
            if (verbose) { NSLog(@"Registered app activated selector"); }
        }
    }
    return self;
}

- (void)dealloc {
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver: self];
}

- (void)spaceChanged:(NSNotification *)notification {
    if (verbose) { NSLog(@"Space changed"); }
    spaceChanged();
}

- (void)appActivated:(NSNotification *)notification {
    if (verbose) { NSLog(@"App activated, waiting %0.3fs", ACTIVATE_DELAY_MS/1000.0); }
    [self performSelector: @selector(onAppActivated) withObject: nil afterDelay: ACTIVATE_DELAY_MS/1000.0];
}

- (void)onAppActivated {
    if (appActivated() && cursorScale != oldScale) {
        if (verbose) { NSLog(@"Set cursor scale after %0.3fs", SCALE_DELAY_MS/1000.0); }
        [self performSelector: @selector(onSetCursorScale:)
            withObject: [NSNumber numberWithFloat: cursorScale]
            afterDelay: SCALE_DELAY_MS/1000.0];

        [self performSelector: @selector(onSetCursorScale:)
            withObject: [NSNumber numberWithFloat: oldScale]
            afterDelay: SCALE_DURATION_MS/1000.0];
    }
}

- (void)onSetCursorScale:(NSNumber *)scale {
    if (verbose) { NSLog(@"Set cursor scale: %@", scale); }
    CGSSetCursorScale(CGSMainConnectionID(), scale.floatValue);
}

- (void)onTick:(NSNumber *)timerInterval {
    [self performSelector: @selector(onTick:)
        withObject: timerInterval
        afterDelay: timerInterval.floatValue];
    onTick();
}

#ifdef FOCUS_FIRST
- (void)windowFocused:(AXUIElementRef)_window {
    if (verbose) { NSLog(@"Window focused, waiting %0.3fs", raiseDelayCount*pollMillis/1000.0); }
    [self performSelector: @selector(onWindowFocused:)
        withObject: [NSNumber numberWithUnsignedLong: (uint64_t) _window]
        afterDelay: raiseDelayCount*pollMillis/1000.0];
}

- (void)onWindowFocused:(NSNumber *)_window {
    if (_window.unsignedLongValue == (uint64_t) _lastFocusedWindow) {
        raiseAndActivate(_lastFocusedWindow, lastFocusedWindow_pid);
    } else if (verbose) { NSLog(@"Ignoring window focused event"); }
}
#endif

- (void)onWindowFocusChanged:(NSNumber *)elementPtr {
    if (!activated_by_task_switcher) {
        if (verbose) { NSLog(@"Window focus changed but not from task switcher, ignoring"); }
        return;  // Double-check filter
    }
    
    if (verbose) { NSLog(@"Processing window focus change from task switcher"); }
    
    AXUIElementRef focusedWindow = (AXUIElementRef)elementPtr.unsignedLongValue;
    
    // Reuse existing warp logic but for the focused window
    if (warpMouse && focusedWindow) {
        CGPoint warpPoint = get_mousepoint(focusedWindow);
        if (warpPoint.x != 0 || warpPoint.y != 0) {
            if (verbose) { NSLog(@"Warping cursor to focused window"); }
            CGWarpMouseCursorPosition(warpPoint);
            
            // Set flag to allow focusOnDemand after cursor warp
            if (focusOnDemand) {
                shouldFocusOnDemand = true;
                if (verbose) { NSLog(@"Cursor warped via Cmd+`, enabling focusOnDemand"); }
            }
        }
    }
    
    // Handle cursor scaling if needed
    if (cursorScale != oldScale) {
        if (verbose) { NSLog(@"Scheduling cursor scaling"); }
        [self performSelector:@selector(onSetCursorScale:) 
                   withObject:[NSNumber numberWithFloat:cursorScale] 
                   afterDelay:SCALE_DELAY_MS/1000.0];
        [self performSelector:@selector(onSetCursorScale:) 
                   withObject:[NSNumber numberWithFloat:oldScale] 
                   afterDelay:SCALE_DURATION_MS/1000.0];
    }
}

- (void)clearWaitingForWindowChange {
    if (waitingForWindowChange) {
        if (verbose) { NSLog(@"Timeout: clearing waitingForWindowChange flag"); }
        waitingForWindowChange = false;
    }
}
@end // MDWorkspaceWatcher

//-----------------------------------------------AX observer callback----------------------------------------------

void windowFocusChangedCallback(AXObserverRef observer, AXUIElementRef element, 
                               CFStringRef notification, void *refcon) {
    if (!waitingForWindowChange) {
        if (verbose) { NSLog(@"Window focus notification received but not waiting, ignoring"); }
        return;  // Filter: only when expecting change
    }
    
    if (verbose) { NSLog(@"Window focus changed notification received"); }
    
    waitingForWindowChange = false;

    // Try to update our tracked focused window id from the AX notification
    CGWindowID focused_wid = 0;
    if (element && _AXUIElementGetWindow(element, &focused_wid) == kAXErrorSuccess) {
        currentFocusedWindowID = focused_wid;
        if (verbose) { NSLog(@"AX notification: updated currentFocusedWindowID to %u", focused_wid); }
    }
    
    // Get the workspace watcher from refcon (passed during setup)
    MDWorkspaceWatcher *watcher = (__bridge MDWorkspaceWatcher *)refcon;
    if (watcher) {
        // Cancel the timeout since we got the notification
        [NSObject cancelPreviousPerformRequestsWithTarget:watcher 
                                                 selector:@selector(clearWaitingForWindowChange) 
                                                   object:nil];
        
        // Delay to match existing app activation timing
        [watcher performSelector:@selector(onWindowFocusChanged:) 
                      withObject:[NSNumber numberWithUnsignedLong:(uint64_t)element]
                      afterDelay:ACTIVATE_DELAY_MS/1000.0];
    }
}

//----------------------------------------------configuration-----------------------------------------------

const NSString *kDelay = @"delay";
const NSString *kWarpX = @"warpX";
const NSString *kWarpY = @"warpY";
const NSString *kScale = @"scale";
const NSString *kVerbose = @"verbose";
const NSString *kAltTaskSwitcher = @"altTaskSwitcher";
const NSString *kIgnoreSpaceChanged = @"ignoreSpaceChanged";
const NSString *kStayFocusedBundleIds = @"stayFocusedBundleIds";
const NSString *kInvertIgnoreApps = @"invertIgnoreApps";
const NSString *kIgnoreApps = @"ignoreApps";
const NSString *kIgnoreTitles = @"ignoreTitles";
const NSString *kMouseDelta = @"mouseDelta";
const NSString *kPollMillis = @"pollMillis";
const NSString *kDisableKey = @"disableKey";

#ifdef FOCUS_FIRST
const NSString *kFocusDelay = @"focusDelay";
NSArray *parametersDictionary = @[kDelay, kWarpX, kWarpY, kScale, kVerbose, kAltTaskSwitcher,
    kFocusDelay, kIgnoreSpaceChanged, kInvertIgnoreApps, kIgnoreApps, kIgnoreTitles,
    kStayFocusedBundleIds, kDisableKey, kMouseDelta, kPollMillis];
#else
NSArray *parametersDictionary = @[kDelay, kWarpX, kWarpY, kScale, kVerbose, kAltTaskSwitcher,
    kIgnoreSpaceChanged, kInvertIgnoreApps, kIgnoreApps, kIgnoreTitles, kStayFocusedBundleIds,
    kDisableKey, kMouseDelta, kPollMillis];
#endif
NSMutableDictionary *parameters = [[NSMutableDictionary alloc] init];

@interface ConfigClass:NSObject
- (NSString *) getFilePath:(NSString *) filename;
- (void) readConfig:(int) argc;
- (void) readHiddenConfig;
- (void) validateParameters;
@end

@implementation ConfigClass
- (NSString *) getFilePath:(NSString *) filename {
    filename = [NSString stringWithFormat: @"%@/%@", NSHomeDirectory(), filename];
    if (not [[NSFileManager defaultManager] fileExistsAtPath: filename]) { filename = NULL; }
    return filename;
}

- (void) readConfig:(int) argc {
    if (argc > 1) {
        // read NSArgumentDomain
        NSUserDefaults *arguments = [NSUserDefaults standardUserDefaults];

        for (id key in parametersDictionary) {
            id arg = [arguments objectForKey: key];
            if (arg != NULL) { parameters[key] = arg; }
        }
    } else {
        [self readHiddenConfig];
    }
    return;
}

- (void) readHiddenConfig {
    // search for dotfiles
    NSString * hiddenConfigFilePath = [self getFilePath: @".AutoRaise"];
    if (!hiddenConfigFilePath) { hiddenConfigFilePath = [self getFilePath: @".config/AutoRaise/config"]; }

    if (hiddenConfigFilePath) {
        NSError * error;
        NSString * configContent = [[NSString alloc]
            initWithContentsOfFile: hiddenConfigFilePath
            encoding: NSUTF8StringEncoding error: &error];

        NSArray * configLines = [configContent componentsSeparatedByString: @"\n"];
        NSString * trimmedLine, * trimmedKey, * trimmedValue, * noQuotesValue;
        NSArray * components;
        for (NSString * line in configLines) {
            trimmedLine = [line stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
            if (not [trimmedLine hasPrefix: @"#"]) {
                components = [trimmedLine componentsSeparatedByString: @"="];
                if ([components count] == 2) {
                    for (id key in parametersDictionary) {
                       trimmedKey = [components[0] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
                       trimmedValue = [components[1] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
                       noQuotesValue = [trimmedValue stringByReplacingOccurrencesOfString: @"\"" withString: @""];
                       if ([trimmedKey isEqual: key]) { parameters[key] = noQuotesValue; }
                    }
                }
            }
        }
    }
    return;
}

- (void) validateParameters {
    // validate and fix wrong/absent parameters
#ifdef FOCUS_FIRST
    if (!parameters[kFocusDelay] && !parameters[kDelay]) {
#else
    if (!parameters[kDelay]) {
#endif
parameters[kDelay] = @"0";    }
    if ([parameters[kPollMillis] intValue] < 20) { parameters[kPollMillis] = @"50"; }
    if ([parameters[kMouseDelta] floatValue] < 0) { parameters[kMouseDelta] = @"0"; }
    if ([parameters[kScale] floatValue] < 1) { parameters[kScale] = @"2.0"; }
    if (!parameters[kDisableKey]) { parameters[kDisableKey] = @"control"; }
    warpMouse =
        parameters[kWarpX] && [parameters[kWarpX] floatValue] >= 0 && [parameters[kWarpX] floatValue] <= 1 &&
        parameters[kWarpY] && [parameters[kWarpY] floatValue] >= 0 && [parameters[kWarpY] floatValue] <= 1;
    
    // focus-on-demand is default; ensure delay defaults to 0 if not specified
    if (!parameters[kDelay]) { parameters[kDelay] = @"0"; }
#ifdef ALTERNATIVE_TASK_SWITCHER
    if (!parameters[kAltTaskSwitcher]) { parameters[kAltTaskSwitcher] = @"true"; }
#endif
#ifdef FOCUS_FIRST
    if (![parameters[kDelay] intValue] && !parameters[kFocusDelay]) { parameters[kFocusDelay] = @"1"; }
    if (!parameters[kDelay] && ![parameters[kFocusDelay] intValue]) { parameters[kDelay] = @"1"; }
#endif
    return;
}
@end // ConfigClass

//------------------------------------------where it all happens--------------------------------------------

void spaceChanged() {
    spaceHasChanged = true;
    oldPoint.x = oldPoint.y = 0;
    
    // Reset focusOnDemand tracking when changing spaces
    if (focusOnDemand) {
        shouldFocusOnDemand = true;
        clearHighlight(); // Clear any existing highlight
        if (verbose) { NSLog(@"Space changed: Reset focusOnDemand tracking"); }
    }
}

bool appActivated() {
    if (verbose) { NSLog(@"App activated"); }
    if (!altTaskSwitcher) {
        if (!activated_by_task_switcher) { return false; }
        activated_by_task_switcher = false;
    }
    appWasActivated = true;

    NSRunningApplication *frontmostApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
    pid_t frontmost_pid = frontmostApp.processIdentifier;

    AXUIElementRef _activatedWindow = NULL;
    AXUIElementRef _frontmostApp = AXUIElementCreateApplication(frontmost_pid);
    AXUIElementCopyAttributeValue(_frontmostApp,
        kAXMainWindowAttribute, (CFTypeRef *) &_activatedWindow);
    if (!_activatedWindow) {
        if (verbose) { NSLog(@"No main window, trying focused window"); }
        AXUIElementCopyAttributeValue(_frontmostApp,
            kAXFocusedWindowAttribute, (CFTypeRef *) &_activatedWindow);
    }
    CFRelease(_frontmostApp);

    if (verbose) { NSLog(@"BundleIdentifier: %@", frontmostApp.bundleIdentifier); }
    bool finder_app = [frontmostApp.bundleIdentifier isEqual: FinderBundleId];
    if (finder_app) {
        if (_activatedWindow) {
            if (is_desktop_window(_activatedWindow)) {
                CFRelease(_activatedWindow);
                _activatedWindow = _previousFinderWindow;
            } else {
                if (_previousFinderWindow) { CFRelease(_previousFinderWindow); }
                _previousFinderWindow = _activatedWindow;
            }
        } else { _activatedWindow = _previousFinderWindow; }
    }

    if (altTaskSwitcher) {
        CGEventRef _event = CGEventCreate(NULL);
        CGPoint mousePoint = CGEventGetLocation(_event);
        if (_event) { CFRelease(_event); }

        bool ignoreActivated = false;
        // TODO: is the uncorrected mousePoint good enough?
        AXUIElementRef _mouseWindow = get_mousewindow(mousePoint);
        if (_mouseWindow) {
            if (!activated_by_task_switcher) {
                pid_t mouseWindow_pid;
                // Checking for mouse movement reduces the problem of the mouse being warped
                // when changing spaces and simultaneously moving the mouse to another screen
                ignoreActivated = fabs(mousePoint.x-oldPoint.x) > 0;
                ignoreActivated = ignoreActivated || fabs(mousePoint.y-oldPoint.y) > 0;
                // Check if the mouse is already hovering above the frontmost app. If
                // for example we only change spaces, we don't want the mouse to warp
                ignoreActivated = ignoreActivated || (AXUIElementGetPid(_mouseWindow,
                    &mouseWindow_pid) == kAXErrorSuccess && mouseWindow_pid == frontmost_pid);
            }
            CFRelease(_mouseWindow);
        } else { // dock or top menu
            // Comment the line below if clicking the dock icons should also
            // warp the mouse. Note this may introduce some unexpected warps
            ignoreActivated = true;
        }

        activated_by_task_switcher = false; // used in the previous code block

        if (ignoreActivated) {
            if (verbose) { NSLog(@"Ignoring app activated"); }
            if (!finder_app && _activatedWindow) { CFRelease(_activatedWindow); }
            return false;
        }
    }

    if (_activatedWindow) {
        if (verbose) { NSLog(@"Warp mouse"); }
        CGPoint warpPoint = get_mousepoint(_activatedWindow);
        CGWarpMouseCursorPosition(warpPoint);
        
        // Set flag to allow focusOnDemand after cursor warp
        if (focusOnDemand) {
            shouldFocusOnDemand = true;
            if (verbose) { NSLog(@"Cursor warped, enabling focusOnDemand"); }
        }
        
        if (!finder_app) { CFRelease(_activatedWindow); }
    }

    return true;
}

void onTick() {
    // When focus-on-demand is enabled, disable all auto-raise logic
    if (focusOnDemand) {
        // Track mouse position to detect movement
        CGEventRef _event = CGEventCreate(NULL);
        CGPoint mousePoint = CGEventGetLocation(_event);
        if (_event) { CFRelease(_event); }
        
        // Check if mouse has moved
        float mouse_x_diff = mousePoint.x - oldPoint.x;
        float mouse_y_diff = mousePoint.y - oldPoint.y;
        bool mouseMoved = fabs(mouse_x_diff) > mouseDelta || fabs(mouse_y_diff) > mouseDelta;
        
        if (mouseMoved && !shouldFocusOnDemand) {
            shouldFocusOnDemand = true;
            if (verbose) { NSLog(@"Mouse moved, enabling focusOnDemand"); }
        }
        
        // Show highlight for window under cursor when mouse moves
        if (mouseMoved) {
            mousePoint = applyCorrectionToPoint(mousePoint);
            AXUIElementRef _targetWindow = get_mousewindow(mousePoint);
            if (_targetWindow) {
                pid_t targetWindow_pid;
                if (AXUIElementGetPid(_targetWindow, &targetWindow_pid) == kAXErrorSuccess) {
                    if (shouldFocusWindow(_targetWindow, targetWindow_pid)) {
                        // Show highlight for any window we enter (even if already focused)
                        showHighlightForWindow(_targetWindow);
                    } else {
                        clearHighlight();
                    }
                }
                CFRelease(_targetWindow);
            } else {
                clearHighlight();
            }
        }
        
        oldPoint = mousePoint;
        return;
    }
    
    // determine if mouseMoved
    CGEventRef _event = CGEventCreate(NULL);
    CGPoint mousePoint = CGEventGetLocation(_event);
    if (_event) { CFRelease(_event); }

    float mouse_x_diff = mousePoint.x-oldPoint.x;
    float mouse_y_diff = mousePoint.y-oldPoint.y;
    oldPoint = mousePoint;

    bool mouseMoved = fabs(mouse_x_diff) > mouseDelta;
    mouseMoved = mouseMoved || fabs(mouse_y_diff) > mouseDelta;
    mouseMoved = mouseMoved || propagateMouseMoved;
    propagateMouseMoved = false;

    // delayCount = 0 -> warp only
#ifdef FOCUS_FIRST
    if (altTaskSwitcher && !delayCount && !raiseDelayCount) { return; }
#else
    if (altTaskSwitcher && !delayCount) { return; }
#endif

    // delayTicks = 0 -> delay disabled
    // delayTicks = 1 -> delay finished
    // delayTicks = n -> delay started
    if (delayTicks > 1) { delayTicks--; }

#ifdef FOCUS_FIRST
    if (!delayCount || raiseDelayCount == 1) {
#endif
        if (@available(macOS 12.00, *)) {
            // the correction should be applied before we return
            // under certain conditions in the code after it. This
            // ensures oldCorrectedPoint always has a recent value.
            if (mouseMoved) {
                NSScreen * screen = findScreen(mousePoint);
                mousePoint.x += mouse_x_diff > 0 ? WINDOW_CORRECTION : -WINDOW_CORRECTION;
                mousePoint.y += mouse_y_diff > 0 ? WINDOW_CORRECTION : -WINDOW_CORRECTION;
                if (screen) {
                    NSScreen * main_screen = NSScreen.screens[0];
                    float screenOriginX = NSMinX(screen.frame) - NSMinX(main_screen.frame);
                    float screenOriginY = NSMaxY(main_screen.frame) - NSMaxY(screen.frame);

                    if (oldPoint.x > screenOriginX + NSWidth(screen.frame) - WINDOW_CORRECTION) {
                        if (verbose) { NSLog(@"Screen edge correction"); }
                        mousePoint.x = screenOriginX + NSWidth(screen.frame) - 1;
                    } else if (oldPoint.x < screenOriginX + WINDOW_CORRECTION - 1) {
                        if (verbose) { NSLog(@"Screen edge correction"); }
                        mousePoint.x = screenOriginX + 1;
                    }

                    if (oldPoint.y > screenOriginY + NSHeight(screen.frame) - WINDOW_CORRECTION) {
                        if (verbose) { NSLog(@"Screen edge correction"); }
                        mousePoint.y = screenOriginY + NSHeight(screen.frame) - 1;
                    } else {
                        float menuBarHeight =
                            fmax(0, NSMaxY(screen.frame) - NSMaxY(screen.visibleFrame) - 1);
                        if (mousePoint.y < screenOriginY + menuBarHeight + MENUBAR_CORRECTION) {
                            if (verbose) { NSLog(@"Menu bar correction"); }
                            mousePoint.y = screenOriginY;
                        }
                    }
                }
                oldCorrectedPoint = mousePoint;
            } else {
                mousePoint = oldCorrectedPoint;
            }
        }
#ifdef FOCUS_FIRST
    }
#endif

    if (ignoreTimes) {
        ignoreTimes--;
        return;
    } else if (appWasActivated) {
        appWasActivated = false;
        return;
    } else if (spaceHasChanged) {
        // spaceHasChanged has priority
        // over waiting for the delay
        if (mouseMoved) { return; }
        else if (!ignoreSpaceChanged) {
            raiseTimes = 3;
            delayTicks = 0;
        }
        spaceHasChanged = false;
    } else if (delayTicks && mouseMoved) {
        delayTicks = 0;
        // propagate the mouseMoved event
        // to restart the delay if needed
        propagateMouseMoved = true;
        return;
    }

    // mouseMoved: we have to decide if the window needs raising
    // delayTicks: count down as long as the mouse doesn't move
    // raiseTimes: the window needs raising a couple of times.
    if (mouseMoved || delayTicks || raiseTimes) {
        // don't raise for as long as something is being dragged (resizing a window for instance)
        bool abort = CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft) ||
            CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight) ||
            dock_active() ||
            mc_active();

        if (!abort && disableKey) {
            CGEventRef _keyDownEvent = CGEventCreateKeyboardEvent(NULL, 0, true);
            CGEventFlags flags = CGEventGetFlags(_keyDownEvent);
            if (_keyDownEvent) { CFRelease(_keyDownEvent); }
            abort = (flags & disableKey) == disableKey;
        }

        NSRunningApplication *frontmostApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
        abort = abort || [stayFocusedBundleIds containsObject: frontmostApp.bundleIdentifier];

        if (abort) {
            if (verbose) { NSLog(@"Abort focus/raise"); }
            raiseTimes = 0;
            delayTicks = 0;
            return;
        }

        AXUIElementRef _mouseWindow = get_mousewindow(mousePoint);
        if (_mouseWindow) {
            pid_t mouseWindow_pid;
            if (AXUIElementGetPid(_mouseWindow, &mouseWindow_pid) == kAXErrorSuccess) {
                bool needs_raise = !invertIgnoreApps;
                AXUIElementRef _mouseWindowApp = AXUIElementCreateApplication(mouseWindow_pid);
                if (needs_raise && titleEquals(_mouseWindow, @[NoTitle, Untitled])) {
                    needs_raise = is_main_window(_mouseWindowApp, _mouseWindow, is_chrome_app(
                        [NSRunningApplication runningApplicationWithProcessIdentifier:
                        mouseWindow_pid].bundleIdentifier));
                    if (verbose && !needs_raise) { NSLog(@"Excluding window"); }
                } else if (needs_raise &&
                    titleEquals(_mouseWindow, @[BartenderBar, Zim, AppStoreSearchResults], ignoreTitles)) {
                    // TODO: make these window title exceptions an ignoreWindowTitles setting.
                    needs_raise = false;
                    if (verbose) { NSLog(@"Excluding window"); }
                } else {
                    if (titleEquals(_mouseWindowApp, ignoreApps)) {
                        needs_raise = invertIgnoreApps;
                        if (verbose) {
                            if (invertIgnoreApps) {
                                NSLog(@"Including app");
                            } else {
                                NSLog(@"Excluding app");
                            }
                        }
                    }
                }
                CFRelease(_mouseWindowApp);
                CGWindowID mouseWindow_id;
                CGWindowID focusedWindow_id;
#ifdef FOCUS_FIRST
                ProcessSerialNumber mouseWindow_psn;
                ProcessSerialNumber focusedWindow_psn;
                ProcessSerialNumber * _focusedWindow_psn = NULL;
#endif
                if (needs_raise) {
                    _AXUIElementGetWindow(_mouseWindow, &mouseWindow_id);
                    pid_t frontmost_pid = frontmostApp.processIdentifier;
                    AXUIElementRef _frontmostApp = AXUIElementCreateApplication(frontmost_pid);
                    AXUIElementRef _focusedWindow = NULL;
                    AXUIElementCopyAttributeValue(
                        _frontmostApp,
                        kAXFocusedWindowAttribute,
                        (CFTypeRef *) &_focusedWindow);
                    if (_focusedWindow) {
                        if (verbose) { logWindowTitle(@"Focused window", _focusedWindow); }
                        _AXUIElementGetWindow(_focusedWindow, &focusedWindow_id);
                        needs_raise = mouseWindow_id != focusedWindow_id;
#ifdef FOCUS_FIRST
                        if (raiseDelayCount) {
#endif
                            needs_raise = needs_raise && !contained_within(_focusedWindow, _mouseWindow);
#ifdef FOCUS_FIRST
                        } else {
                            needs_raise = needs_raise && is_main_window(_frontmostApp, _focusedWindow,
                                is_chrome_app(frontmostApp.bundleIdentifier)) && (
                                mouseWindow_pid != frontmost_pid ||
                                !contained_within(_focusedWindow, _mouseWindow));
                        }
                        if (needs_raise && delayCount && raiseDelayCount != 1) {
                            OSStatus error = GetProcessForPID(frontmost_pid, &focusedWindow_psn);
                            if (!error) { _focusedWindow_psn = &focusedWindow_psn; }
                        }
#endif
                        CFRelease(_focusedWindow);
                    } else {
                        if (verbose) { NSLog(@"No focused window"); }
                        AXUIElementRef _activatedWindow = NULL;
                        AXUIElementCopyAttributeValue(_frontmostApp,
                            kAXMainWindowAttribute, (CFTypeRef *) &_activatedWindow);
                        if (_activatedWindow) {
                          needs_raise = false;
                          CFRelease(_activatedWindow);
                        }
                    }
                    CFRelease(_frontmostApp);
                }

                if (needs_raise) {
                    if (!delayTicks) {
                        // start the delay
                        delayTicks = delayCount;
                    }
                    if (raiseTimes || delayTicks == 1) {
                        delayTicks = 0; // disable delay

                        if (raiseTimes) { raiseTimes--; }
                        else { raiseTimes = 3; }
#ifdef FOCUS_FIRST
                        if (delayCount && raiseDelayCount != 1) {
                            OSStatus error = GetProcessForPID(mouseWindow_pid, &mouseWindow_psn);
                            if (!error) {
                                bool floating_window = false;
                                CFStringRef _element_sub_role = NULL;
                                AXUIElementCopyAttributeValue(
                                    _mouseWindow,
                                    kAXSubroleAttribute,
                                    (CFTypeRef *) &_element_sub_role);
                                if (_element_sub_role) {
                                    floating_window =
                                        CFEqual(_element_sub_role, kAXFloatingWindowSubrole) ||
                                        CFEqual(_element_sub_role, kAXSystemFloatingWindowSubrole) ||
                                        CFEqual(_element_sub_role, kAXUnknownSubrole);
                                    CFRelease(_element_sub_role);
                                }
                                if (!floating_window) {
                                    // TODO: method below seems unable to focus floating windows
                                    window_manager_focus_window_without_raise(&mouseWindow_psn,
                                        mouseWindow_id, _focusedWindow_psn, focusedWindow_id);
                                } else if (verbose) { NSLog(@"Unable to focus floating window"); }
                                if (_lastFocusedWindow) { CFRelease(_lastFocusedWindow); }
                                _lastFocusedWindow = _mouseWindow;
                                lastFocusedWindow_pid = mouseWindow_pid;
                                if (raiseDelayCount) { [workspaceWatcher windowFocused: _lastFocusedWindow]; }
                            }
                        } else {
#endif
                        raiseAndActivate(_mouseWindow, mouseWindow_pid);
#ifdef FOCUS_FIRST
                        }
#endif
                    }
                } else {
                    raiseTimes = 0;
                    delayTicks = 0;
                }
            }
#ifdef FOCUS_FIRST
            if (_mouseWindow != _lastFocusedWindow) {
#endif
                CFRelease(_mouseWindow);
#ifdef FOCUS_FIRST
            }
#endif
        } else {
            raiseTimes = 0;
            delayTicks = 0;
        }
    }
}

CGEventRef eventTapHandler(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    static bool commandTabPressed = false;
    if (type == kCGEventFlagsChanged && commandTabPressed) {
        if (!activated_by_task_switcher) {
            activated_by_task_switcher = true;
            // Extend ignore period for focus-on-demand to prevent race condition
            ignoreTimes = 30;
            
            // Reset focusOnDemand tracking to allow focus after task switch
            if (focusOnDemand) {
                shouldFocusOnDemand = true;
                if (verbose) { NSLog(@"Cmd+Tab: Reset focusOnDemand tracking"); }
            }
        }
    }

    commandTabPressed = false;
    if (type == kCGEventKeyDown) {
        CGKeyCode keycode = (CGKeyCode) CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (keycode == kVK_Tab) {
            CGEventFlags flags = CGEventGetFlags(event);
            commandTabPressed = (flags & kCGEventFlagMaskCommand) == kCGEventFlagMaskCommand;
        } else if ((warpMouse || focusOnDemand) && keycode == kVK_ANSI_Grave) {
            CGEventFlags flags = CGEventGetFlags(event);
            if ((flags & kCGEventFlagMaskCommand) == kCGEventFlagMaskCommand) {
                if (!activated_by_task_switcher) {
                    activated_by_task_switcher = true;
                    waitingForWindowChange = true;  // Set flag to wait for AX notification
                    // Extend ignore period for focus-on-demand to prevent race condition
                    ignoreTimes = 30;
                    
                    // Reset focusOnDemand tracking to allow focus after task switch
                    if (focusOnDemand) {
                        shouldFocusOnDemand = true;
                        if (verbose) { NSLog(@"Cmd+`: Reset focusOnDemand tracking"); }
                    }
                    
                    if (verbose) { NSLog(@"Cmd+` detected, waiting for window focus change notification"); }
                    // Schedule timeout to clear flag if notification doesn't arrive
                    [workspaceWatcher performSelector:@selector(clearWaitingForWindowChange) 
                                           withObject:nil 
                                           afterDelay:1.0];  // 1 second timeout
                    // Remove synchronous appActivated() call - now handled by AX observer
                }
            }
        }
    } else if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (verbose) { NSLog(@"Got event tap disabled event, re-enabling..."); }
        CGEventTapEnable(eventTap, true);
    }

    // Focus-on-demand logic - handle AFTER task switcher logic
    // Only trigger focus for explicit key presses or mouse button down events
    if (focusOnDemand && !activated_by_task_switcher && (
            type == kCGEventKeyDown ||
            type == kCGEventLeftMouseDown ||
            type == kCGEventRightMouseDown ||
            type == kCGEventOtherMouseDown)) {
        handleFocusOnDemand(type, event);
    }

    return event;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        ConfigClass * config = [[ConfigClass alloc] init];
        [config readConfig: argc];
        [config validateParameters];

        delayCount         = [parameters[kDelay] intValue];
        warpX              = [parameters[kWarpX] floatValue];
        warpY              = [parameters[kWarpY] floatValue];
        cursorScale        = [parameters[kScale] floatValue];
        verbose            = [parameters[kVerbose] boolValue];
        altTaskSwitcher    = [parameters[kAltTaskSwitcher] boolValue];
        mouseDelta         = [parameters[kMouseDelta] floatValue];
        pollMillis         = [parameters[kPollMillis] intValue];
        ignoreSpaceChanged = [parameters[kIgnoreSpaceChanged] boolValue];
        invertIgnoreApps   = [parameters[kInvertIgnoreApps] boolValue];
        // focusOnDemand is enabled by default

        printf("\nv%s by sbmpost(c) 2025, usage:\n\nAutoRaise\n", AUTORAISE_VERSION);
        printf("  -pollMillis <20, 30, 40, 50, ...>\n");
        printf("  -delay <0=no-raise, 1=no-delay, 2=%dms, 3=%dms, ...>\n", pollMillis, pollMillis*2);
#ifdef FOCUS_FIRST
        printf("  -focusDelay <0=no-focus, 1=no-delay, 2=%dms, 3=%dms, ...>\n", pollMillis, pollMillis*2);
#endif
        printf("  -warpX <0.5> -warpY <0.5> -scale <2.0>\n");
        printf("  -altTaskSwitcher <true|false>\n");
        printf("  -ignoreSpaceChanged <true|false>\n");
        printf("  -invertIgnoreApps <true|false>\n");
        printf("  -ignoreApps \"<App1,App2,...>\"\n");
        printf("  -ignoreTitles \"<Regex1,Regex2,...>\"\n");
        printf("  -stayFocusedBundleIds \"<Id1,Id2,...>\"\n");
        printf("  -disableKey <control|option|disabled>\n");
        printf("  -mouseDelta <0.1>\n");
        
        printf("  -verbose <true|false>\n\n");

        printf("Started with:\n");
        printf("  * pollMillis: %dms\n", pollMillis);
        if (delayCount) {
            printf("  * delay: %dms\n", (delayCount-1)*pollMillis);
        } else {
            printf("  * delay: disabled\n");
        }
#ifdef FOCUS_FIRST
        if ([parameters[kFocusDelay] intValue]) {
            raiseDelayCount = delayCount;
            delayCount = [parameters[kFocusDelay] intValue];
            printf("  * focusDelay: %dms\n", (delayCount-1)*pollMillis);
        } else {
            raiseDelayCount = 1;
            printf("  * focusDelay: disabled\n");
        }
#endif

        if (warpMouse) {
            printf("  * warpX: %.1f, warpY: %.1f, scale: %.1f\n", warpX, warpY, cursorScale);
            printf("  * altTaskSwitcher: %s\n", altTaskSwitcher ? "true" : "false");
        }

        printf("  * ignoreSpaceChanged: %s\n", ignoreSpaceChanged ? "true" : "false");
        printf("  * invertIgnoreApps: %s\n", invertIgnoreApps ? "true" : "false");

        NSMutableArray * ignoreA;
        if (parameters[kIgnoreApps]) {
            ignoreA = [[NSMutableArray alloc] initWithArray:
                [parameters[kIgnoreApps] componentsSeparatedByString:@","]];
        } else { ignoreA = [[NSMutableArray alloc] init]; }

        for (id ignoreApp in ignoreA) {
            printf("  * ignoreApp: %s\n", [ignoreApp UTF8String]);
        }
        [ignoreA addObject: AssistiveControl];
        ignoreApps = [ignoreA copy];

        NSMutableArray * ignoreT;
        if (parameters[kIgnoreTitles]) {
            ignoreT = [[NSMutableArray alloc] initWithArray:
                [parameters[kIgnoreTitles] componentsSeparatedByString: @","]];
        } else { ignoreT = [[NSMutableArray alloc] init]; }

        for (id ignoreTitle in ignoreT) {
            printf("  * ignoreTitle: %s\n", [ignoreTitle UTF8String]);
        }
        ignoreTitles = [ignoreT copy];

        NSMutableArray * stayFocused;
        if (parameters[kStayFocusedBundleIds]) {
            stayFocused = [[NSMutableArray alloc] initWithArray:
                [parameters[kStayFocusedBundleIds] componentsSeparatedByString: @","]];
        } else { stayFocused = [[NSMutableArray alloc] init]; }

        for (id stayFocusedBundleId in stayFocused) {
            printf("  * stayFocusedBundleId: %s\n", [stayFocusedBundleId UTF8String]);
        }
        stayFocusedBundleIds = [stayFocused copy];

        if ([parameters[kDisableKey] isEqualToString: @"control"]) {
            printf("  * disableKey: control\n");
            disableKey = kCGEventFlagMaskControl;
        } else if ([parameters[kDisableKey] isEqualToString: @"option"]) {
            printf("  * disableKey: option\n");
            disableKey = kCGEventFlagMaskAlternate;
        } else { printf("  * disableKey: disabled\n"); }

        if (mouseDelta) { printf("  * mouseDelta: %.1f\n", mouseDelta); }

        printf("  * focusOnDemand: enabled (default)\n");
        printf("  * verbose: %s\n", verbose ? "true" : "false");
#if defined OLD_ACTIVATION_METHOD or defined FOCUS_FIRST or defined ALTERNATIVE_TASK_SWITCHER
        printf("\nCompiled with:\n");
#ifdef OLD_ACTIVATION_METHOD
        printf("  * OLD_ACTIVATION_METHOD\n");
#endif
#ifdef FOCUS_FIRST
        printf("  * EXPERIMENTAL_FOCUS_FIRST\n");
#endif
#ifdef ALTERNATIVE_TASK_SWITCHER
        printf("  * ALTERNATIVE_TASK_SWITCHER\n");
#endif
#endif
        printf("\n");

        NSDictionary * options = @{(id) CFBridgingRelease(kAXTrustedCheckOptionPrompt): @YES};
        bool trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef) options);
        if (verbose) { NSLog(@"AXIsProcessTrusted: %s", trusted ? "YES" : "NO"); }

        if (!trusted) {
            // Prompt the user to grant Accessibility permission and then exit immediately.
            // Exiting makes it straightforward for the user to grant permission in System Settings
            // without the running app interfering. The user must restart the app after granting.
            NSLog(@"Accessibility permission is required. Please grant AutoRaise permission in System Settings -> Privacy & Security -> Accessibility.");
            NSLog(@"AutoRaise will now quit so you can grant the permission. Please restart AutoRaise after granting the permission.");
            // Small sleep to allow the permission prompt to be presented on some macOS versions
            // before the app exits. This is optional but helps the system show the UI.
            sleep(1);
            // Exit the process so the user can grant permission; they will need to relaunch.
            exit(0);
        }

        CGSGetCursorScale(CGSMainConnectionID(), &oldScale);
        if (verbose) { NSLog(@"System cursor scale: %f", oldScale); }

        CFRunLoopSourceRef runLoopSource = NULL;
        CGEventMask eventMask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventFlagsChanged);
        
        // Focus-on-demand always enabled: include additional events
        eventMask |= CGEventMaskBit(kCGEventLeftMouseDown) |
                    CGEventMaskBit(kCGEventRightMouseDown) |
                    CGEventMaskBit(kCGEventOtherMouseDown) |
                    CGEventMaskBit(kCGEventScrollWheel);
        
        eventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
            eventMask, eventTapHandler, NULL);
        if (eventTap) {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
            if (runLoopSource) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
                CGEventTapEnable(eventTap, true);
            }
        }
        if (verbose) { NSLog(@"Got run loop source: %s", runLoopSource ? "YES" : "NO"); }

        workspaceWatcher = [[MDWorkspaceWatcher alloc] init];

        // Setup AX observer for window focus changes (needed for Cmd+` cursor warp)
        // Must be done after workspaceWatcher is created so we can pass it as refcon
        if (warpMouse || focusOnDemand) {
            AXError axError = AXObserverCreate(getpid(), windowFocusChangedCallback, &windowObserver);
            if (axError == kAXErrorSuccess && windowObserver) {
                axError = AXObserverAddNotification(windowObserver, _accessibility_object, 
                                                   kAXFocusedWindowChangedNotification, 
                                                   (__bridge void *)workspaceWatcher);
                if (axError == kAXErrorSuccess) {
                    CFRunLoopAddSource(CFRunLoopGetCurrent(), 
                                       AXObserverGetRunLoopSource(windowObserver), 
                                       kCFRunLoopDefaultMode);
                    if (verbose) { NSLog(@"AX observer for window focus changes: SUCCESS"); }
                } else {
                    if (verbose) { NSLog(@"Failed to add AX notification: %d", axError); }
                    if (windowObserver) {
                        CFRelease(windowObserver);
                        windowObserver = NULL;
                    }
                }
            } else {
                if (verbose) { NSLog(@"Failed to create AX observer: %d", axError); }
            }
        }
#ifdef FOCUS_FIRST
        if (altTaskSwitcher || raiseDelayCount || delayCount) {
#else
        if (altTaskSwitcher || delayCount) {
#endif
            [workspaceWatcher onTick: [NSNumber numberWithFloat: pollMillis/1000.0]];
        }

        findDockApplication();
        findDesktopOrigin();
        
        // Cleanup handler for when app terminates
        [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationWillTerminateNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification *note) {
            clearHighlight();
            // Reset cursor scale on exit
            CGSSetCursorScale(CGSMainConnectionID(), oldScale);
        }];
        
        [[NSApplication sharedApplication] run];
    }
    return 0;
}
