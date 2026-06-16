/*
 * SelectToClipboard plugin for Notepad++ macOS
 * Ported from SelectToClipboard by Jakub Dvorak
 *
 * Automatically copies selected text to the system clipboard whenever
 * the selection changes (when enabled).
 *
 * Original: https://github.com/KakakuJin/SelectToClipboard
 * License: GPLv2
 */

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"

#import <Cocoa/Cocoa.h>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

// ── Plugin state ────────────────────────────────────────────────────────

static const char *PLUGIN_NAME = "Selection to Clipboard";
static const int NB_FUNC = 2;
static FuncItem funcItem[NB_FUNC];
static NppData nppData;

static bool bCopySelected = false;

// Track selection state to avoid redundant copies
struct SelPos {
    intptr_t selBeg;
    intptr_t selEnd;
    intptr_t currentTabId;
};
static SelPos selPos = {0, 0, 0};

// ── Forward declarations ────────────────────────────────────────────────

static void doUpdateCopySelected();
static void doAboutDlg();
static void doCopySelection();
static void CopyRoutine();

// ── Helpers ─────────────────────────────────────────────────────────────

static NppHandle getCurScintilla()
{
    int which = -1;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    if (which == -1) return 0;
    return (which == 0) ? nppData._scintillaMainHandle : nppData._scintillaSecondHandle;
}

static intptr_t sci(NppHandle h, uint32_t msg, uintptr_t w = 0, intptr_t l = 0)
{
    return nppData._sendMessage(h, msg, w, l);
}

// ── Settings persistence (JSON) ─────────────────────────────────────────

static NSString *settingsPath()
{
    // Ask the host for its plugin config directory (creates it if needed).
    // Falls back to ~/Library/Application Support/Nextpad++/plugins/Config if the
    // host returns empty (it does not on shipped versions).
    char buf[1024] = {};
    nppData._sendMessage(nppData._nppHandle,
                         NPPM_GETPLUGINSCONFIGDIR,
                         (uintptr_t)sizeof(buf),
                         (intptr_t)buf);
    NSString *dir;
    if (buf[0] != '\0') {
        dir = [NSString stringWithUTF8String:buf];
    } else {
        dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                   NSUserDomainMask, YES).firstObject
                   stringByAppendingPathComponent:@"Nextpad++/plugins/Config"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }
    return [dir stringByAppendingPathComponent:@"SelectToClipboard.json"];
}

static void loadSettings()
{
    @autoreleasepool {
        // Migrate from the pre-fix settings location (~/.nextpad++/SelectToClipboard.json)
        // to the host's plugin config directory. Silently no-op if nothing
        // to migrate or the destination already exists.
        NSString *newPath = settingsPath();
        NSString *oldPath = [NSHomeDirectory() stringByAppendingPathComponent:
                             @".nextpad++/SelectToClipboard.json"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![newPath isEqualToString:oldPath] &&
            [fm fileExistsAtPath:oldPath] &&
            ![fm fileExistsAtPath:newPath]) {
            [fm moveItemAtPath:oldPath toPath:newPath error:nil];
        }

        NSData *data = [NSData dataWithContentsOfFile:newPath];
        if (!data) return;
        NSError *err = nil;
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if (!dict || err) return;
        NSNumber *val = dict[@"CopySelected"];
        if (val) bCopySelected = [val boolValue];
    }
}

static void saveSettings()
{
    @autoreleasepool {
        NSDictionary *dict = @{@"CopySelected": @(bCopySelected)};
        NSError *err = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&err];
        if (data && !err) {
            [data writeToFile:settingsPath() atomically:YES];
        }
    }
}

// ── Menu check helper ───────────────────────────────────────────────────

static void updateMenuCheck()
{
    nppData._sendMessage(nppData._nppHandle, NPPM_SETMENUITEMCHECK,
                         (uintptr_t)funcItem[0]._cmdID,
                         (intptr_t)(bCopySelected ? 1 : 0));
}

// ── Clipboard insertion ─────────────────────────────────────────────────

// Binary-safe: takes raw bytes + length, never walks a null terminator.
// Scintilla buffers are UTF-8 by default on this host, so we try UTF-8
// first. If the bytes aren't valid UTF-8 (rare for source code, possible
// for mixed-encoding files), fall back to Latin-1 which accepts all byte
// values so no content is dropped.
static void insertTextToClipboard(const char *data, size_t length)
{
    if (!data || length == 0) return;

    @autoreleasepool {
        NSString *str = [[NSString alloc] initWithBytes:data
                                                 length:length
                                               encoding:NSUTF8StringEncoding];
        if (!str) {
            str = [[NSString alloc] initWithBytes:data
                                           length:length
                                         encoding:NSISOLatin1StringEncoding];
        }
        if (!str) return;

        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:str forType:NSPasteboardTypeString];
    }
}

// ── Copy routine ────────────────────────────────────────────────────────

static void CopyRoutine()
{
    NppHandle h = getCurScintilla();
    if (!h) return;

    intptr_t p1 = sci(h, SCI_GETSELECTIONSTART);
    intptr_t p2 = sci(h, SCI_GETSELECTIONEND);
    if (p1 >= p2) return;

    // Get EOL type for rectangular selections
    int eolMode = (int)sci(h, SCI_GETEOLMODE);
    const char *eolStr = "\n";
    if (eolMode == 0) eolStr = "\r\n";
    else if (eolMode == 1) eolStr = "\r";

    bool isRect = sci(h, SCI_SELECTIONISRECTANGLE) != 0;

    intptr_t blockStart = sci(h, SCI_LINEFROMPOSITION, (uintptr_t)p1);
    intptr_t blockEnd = sci(h, SCI_LINEFROMPOSITION, (uintptr_t)p2);
    intptr_t blockLines = blockEnd - blockStart + 1;

    std::string result;

    for (intptr_t ln = 0; ln < blockLines; ln++) {
        intptr_t ls = sci(h, SCI_GETLINESELSTARTPOSITION, (uintptr_t)(blockStart + ln));
        intptr_t le = sci(h, SCI_GETLINESELENDPOSITION, (uintptr_t)(blockStart + ln));
        if (ls == -1 || le == -1) continue;

        intptr_t len = le - ls;
        // Defensive — negative length means the call returned something
        // unexpected; don't try to read.
        if (len < 0) continue;

        // Note: len == 0 is a LEGITIMATE case for stream selection on empty
        // lines (the selection passes through a blank line — no bytes to
        // read, but the line's trailing newline still belongs in the output).
        // The read below is skipped for len == 0 but the EOL append block
        // further down still fires, preserving the empty line in the copy.

        if (len > 0) {
            // Allocate len+1 for SCI_GETTEXTRANGEFULL's trailing NUL,
            // but only copy the real byte count into `result` (length-aware
            // append, so embedded NULs in the selection survive).
            std::vector<char> buf((size_t)len + 1, '\0');
            struct Sci_TextRangeFull tr;
            tr.chrg.cpMin = (Sci_PositionCR)ls;
            tr.chrg.cpMax = (Sci_PositionCR)le;
            tr.lpstrText = buf.data();
            sci(h, SCI_GETTEXTRANGEFULL, 0, (intptr_t)&tr);
            result.append(buf.data(), (size_t)len);
        }

        // Add EOL between lines
        if (isRect && ln + 1 < blockLines) {
            result.append(eolStr);
        } else if (!isRect && ln + 1 < blockLines) {
            // For stream selection, include the line ending bytes from
            // the document so CRLF vs LF is preserved verbatim.
            intptr_t linePos = sci(h, SCI_POSITIONFROMLINE, (uintptr_t)(blockStart + ln));
            intptr_t lineLen = sci(h, SCI_LINELENGTH, (uintptr_t)(blockStart + ln));
            intptr_t lineEnd = linePos + lineLen;
            if (le < lineEnd) {
                intptr_t eolLen = lineEnd - le;
                if (eolLen > 0 && eolLen <= 2) {
                    char eolBuf[3] = {0};
                    struct Sci_TextRangeFull eolTr;
                    eolTr.chrg.cpMin = (Sci_PositionCR)le;
                    eolTr.chrg.cpMax = (Sci_PositionCR)lineEnd;
                    eolTr.lpstrText = eolBuf;
                    sci(h, SCI_GETTEXTRANGEFULL, 0, (intptr_t)&eolTr);
                    result.append(eolBuf, (size_t)eolLen);
                }
            }
        }
    }

    insertTextToClipboard(result.data(), result.size());
}

// ── Selection change handler ────────────────────────────────────────────

static void doCopySelection()
{
    NppHandle h = getCurScintilla();
    if (!h) return;

    intptr_t p1 = sci(h, SCI_GETSELECTIONSTART);
    intptr_t p2 = sci(h, SCI_GETSELECTIONEND);
    intptr_t tabId = nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTBUFFERID, 0, 0);

    // When switching tabs, just record the new position
    if (selPos.currentTabId != tabId) {
        selPos.selBeg = p1;
        selPos.selEnd = p2;
        selPos.currentTabId = tabId;
        return;
    }

    // Only copy if the selection actually changed and something is selected
    if ((selPos.selBeg != p1 || selPos.selEnd != p2) && p2 > p1 && selPos.selEnd != 0) {
        CopyRoutine();
    }

    selPos.selBeg = p1;
    selPos.selEnd = p2;
    selPos.currentTabId = tabId;
}

// ── Command functions ───────────────────────────────────────────────────

static void doUpdateCopySelected()
{
    bCopySelected = !bCopySelected;
    updateMenuCheck();

    // Reset the selection-tracking state on every toggle so the plugin
    // always starts from a clean slate. Without this, stale last-known
    // (selBeg, selEnd) values from before the toggle could either cause
    // a spurious copy the moment the user's selection changes, or miss
    // the first legitimate copy because the sentinel guard matches.
    selPos.selBeg = 0;
    selPos.selEnd = 0;
    selPos.currentTabId = 0;

    // Persist on every toggle so the state survives crashes, force-quits,
    // and silent quits that may not fire NPPN_SHUTDOWN.
    saveSettings();
}

static void doAboutDlg()
{
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"About Selection to Clipboard";
        alert.informativeText =
            @"Version: 1.0.0 (macOS port)\n\n"
            @"License: GPL v2\n\n"
            @"Author: Jakub Dvorak <dvorak.jakub@outlook.com>\n\n"
            @"Auto-copies the current selection to the system clipboard. "
            @"Enabling this feature will overwrite your clipboard every "
            @"time you change the selection.";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
}

// ── Plugin exports ──────────────────────────────────────────────────────

extern "C" NPP_EXPORT void setInfo(NppData data)
{
    nppData = data;

    // Load saved settings
    loadSettings();

    // Set up menu items
    strlcpy(funcItem[0]._itemName, "Auto copy selection to clipboard", NPP_MENU_ITEM_SIZE);
    funcItem[0]._pFunc = doUpdateCopySelected;
    funcItem[0]._init2Check = bCopySelected;
    funcItem[0]._pShKey = nullptr;

    strlcpy(funcItem[1]._itemName, "About", NPP_MENU_ITEM_SIZE);
    funcItem[1]._pFunc = doAboutDlg;
    funcItem[1]._init2Check = false;
    funcItem[1]._pShKey = nullptr;
}

extern "C" NPP_EXPORT const char *getName()
{
    return PLUGIN_NAME;
}

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF)
{
    *nbF = NB_FUNC;
    return funcItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification *notifyCode)
{
    switch (notifyCode->nmhdr.code) {
        case NPPN_SHUTDOWN:
            saveSettings();
            break;

        case SCN_UPDATEUI:
            if (bCopySelected) {
                doCopySelection();
            }
            break;

        case NPPN_READY:
            updateMenuCheck();
            break;

        default:
            break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t /*msg*/, uintptr_t /*wParam*/, intptr_t /*lParam*/)
{
    return 1;
}
