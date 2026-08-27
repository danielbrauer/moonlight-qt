#include "localcursor.h"

#include "SDL_compat.h"
#include "path.h"
#include <Limelight.h>

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QHash>
#include <QList>
#include <QSet>
#include <QtGlobal>

#include <cmath>
#include <malloc/malloc.h>
#include <objc/runtime.h>

// SDL keeps a retained NSCursor* inside its private SDL_Cursor state, which
// the SDL Cocoa view installs via -resetCursorRects. We create cursors through
// the public SDL API and swap in our own NSCursor so SDL's focus/show/hide
// logic keeps working unmodified.
//
// The private layout differs between SDL2 (NSCursor* directly in the
// SDL_Cursor) and SDL3/sdl2-compat (NSCursor* inside a separate driver data
// block whose layout has changed across SDL3 releases), so rather than
// hard-code a layout we locate the slot by scanning the malloc blocks for a
// word whose isa matches NSCursor. If that fails we fall back to SDL's own
// cursor APIs, which work but are not Retina-aware for raster cursors.

// Exported by libobjc for debuggers; masks the class pointer out of a packed isa
extern "C" const uintptr_t objc_debug_isa_class_mask;

static bool isNSCursorObject(void* p)
{
    if (p == nullptr || malloc_zone_from_ptr(p) == nullptr || malloc_size(p) < sizeof(uintptr_t)) {
        return false;
    }

    uintptr_t isa = *(uintptr_t*)p;
    uintptr_t cls = (uintptr_t)[NSCursor class];
    return isa == cls || (isa & objc_debug_isa_class_mask) == cls;
}

// Returns the address of the NSCursor* inside an SDL_Cursor, or nullptr
static void** findNativeCursorSlot(SDL_Cursor* cursor)
{
    if (cursor == nullptr || malloc_zone_from_ptr(cursor) == nullptr) {
        return nullptr;
    }

    void** words = (void**)cursor;
    size_t wordCount = malloc_size(cursor) / sizeof(void*);
    for (size_t i = 0; i < wordCount && i < 16; i++) {
        void* p = words[i];
        if (p == nullptr || malloc_zone_from_ptr(p) == nullptr) {
            continue;
        }

        // SDL2: NSCursor directly in the SDL_Cursor
        if (isNSCursorObject(p)) {
            return &words[i];
        }

        // SDL3: NSCursor inside a driver data block
        void** inner = (void**)p;
        size_t innerCount = malloc_size(p) / sizeof(void*);
        for (size_t j = 0; j < innerCount && j < 16; j++) {
            if (isNSCursorObject(inner[j])) {
                return &inner[j];
            }
        }
    }

    return nullptr;
}

// Points per host-nominal-pixel at pointer scale 1.0. Chosen so a 24 px
// nominal Adwaita arrow ends up roughly the size of NSCursor.arrowCursor.
// Override with LOCAL_CURSOR_SCALE for tuning by eye.
#define DEFAULT_POINTS_PER_NOMINAL_PIXEL (4.0f / 3.0f)

enum class NativeCursorKind {
    Hidden,
    Arrow,
    IBeam,
    IBeamVertical,
    PointingHand,
    OpenHand,
    ClosedHand,
    Crosshair,
    NotAllowed,
    ColumnResize,     // divider between columns
    RowResize,        // divider between rows
    FrameResizeEW,    // frame edge, both directions
    FrameResizeNS,
    FrameResizeE,     // frame edge, one direction
    FrameResizeW,
    FrameResizeN,
    FrameResizeS,
    FrameResizeNWSE,  // frame corner, both directions
    FrameResizeNESW,
    FrameResizeNW,    // frame corner, one direction
    FrameResizeSE,
    FrameResizeNE,
    FrameResizeSW,
    ContextualMenu,
    DragCopy,
    DragLink,
    ZoomIn,
    ZoomOut,
    Raster,
};

struct NamedCursorEntry {
    const char* name;
    NativeCursorKind kind;
};

// Well-known cursor names (CSS names and legacy X11 aliases) mapped to
// native cursors. This table is the client half of the protocol contract:
// the host only sends NAMED shapes for names in this list.
static const NamedCursorEntry k_NamedCursors[] = {
    { "default", NativeCursorKind::Arrow },
    { "left_ptr", NativeCursorKind::Arrow },
    { "arrow", NativeCursorKind::Arrow },
    { "top_left_arrow", NativeCursorKind::Arrow },

    { "text", NativeCursorKind::IBeam },
    { "xterm", NativeCursorKind::IBeam },
    { "ibeam", NativeCursorKind::IBeam },

    { "vertical-text", NativeCursorKind::IBeamVertical },

    { "pointer", NativeCursorKind::PointingHand },
    { "hand", NativeCursorKind::PointingHand },
    { "hand1", NativeCursorKind::PointingHand },
    { "hand2", NativeCursorKind::PointingHand },
    { "pointing_hand", NativeCursorKind::PointingHand },

    { "grab", NativeCursorKind::OpenHand },
    { "openhand", NativeCursorKind::OpenHand },
    { "fleur", NativeCursorKind::OpenHand },
    { "all-scroll", NativeCursorKind::OpenHand },
    { "move", NativeCursorKind::OpenHand },
    { "size_all", NativeCursorKind::OpenHand },

    { "grabbing", NativeCursorKind::ClosedHand },
    { "closedhand", NativeCursorKind::ClosedHand },
    { "dnd-move", NativeCursorKind::ClosedHand },

    { "crosshair", NativeCursorKind::Crosshair },
    { "cross", NativeCursorKind::Crosshair },
    { "tcross", NativeCursorKind::Crosshair },
    { "cell", NativeCursorKind::Crosshair },
    { "plus", NativeCursorKind::Crosshair },

    { "not-allowed", NativeCursorKind::NotAllowed },
    { "no-drop", NativeCursorKind::NotAllowed },
    { "crossed_circle", NativeCursorKind::NotAllowed },
    { "forbidden", NativeCursorKind::NotAllowed },
    { "dnd-no-drop", NativeCursorKind::NotAllowed },

    // Dividers between columns/rows
    { "col-resize", NativeCursorKind::ColumnResize },
    { "split_h", NativeCursorKind::ColumnResize },
    { "row-resize", NativeCursorKind::RowResize },
    { "split_v", NativeCursorKind::RowResize },

    // Frame edges, both directions
    { "ew-resize", NativeCursorKind::FrameResizeEW },
    { "sb_h_double_arrow", NativeCursorKind::FrameResizeEW },
    { "h_double_arrow", NativeCursorKind::FrameResizeEW },
    { "size_hor", NativeCursorKind::FrameResizeEW },
    { "ns-resize", NativeCursorKind::FrameResizeNS },
    { "sb_v_double_arrow", NativeCursorKind::FrameResizeNS },
    { "v_double_arrow", NativeCursorKind::FrameResizeNS },
    { "size_ver", NativeCursorKind::FrameResizeNS },

    // Frame edges, one direction
    { "e-resize", NativeCursorKind::FrameResizeE },
    { "right_side", NativeCursorKind::FrameResizeE },
    { "right_arrow", NativeCursorKind::FrameResizeE },
    { "w-resize", NativeCursorKind::FrameResizeW },
    { "left_side", NativeCursorKind::FrameResizeW },
    { "left_arrow", NativeCursorKind::FrameResizeW },
    { "n-resize", NativeCursorKind::FrameResizeN },
    { "top_side", NativeCursorKind::FrameResizeN },
    { "up_arrow", NativeCursorKind::FrameResizeN },
    { "s-resize", NativeCursorKind::FrameResizeS },
    { "bottom_side", NativeCursorKind::FrameResizeS },
    { "down_arrow", NativeCursorKind::FrameResizeS },

    // Frame corners, both directions
    { "nwse-resize", NativeCursorKind::FrameResizeNWSE },
    { "size_fdiag", NativeCursorKind::FrameResizeNWSE },
    { "nesw-resize", NativeCursorKind::FrameResizeNESW },
    { "size_bdiag", NativeCursorKind::FrameResizeNESW },

    // Frame corners, one direction
    { "nw-resize", NativeCursorKind::FrameResizeNW },
    { "top_left_corner", NativeCursorKind::FrameResizeNW },
    { "se-resize", NativeCursorKind::FrameResizeSE },
    { "bottom_right_corner", NativeCursorKind::FrameResizeSE },
    { "ne-resize", NativeCursorKind::FrameResizeNE },
    { "top_right_corner", NativeCursorKind::FrameResizeNE },
    { "sw-resize", NativeCursorKind::FrameResizeSW },
    { "bottom_left_corner", NativeCursorKind::FrameResizeSW },

    { "context-menu", NativeCursorKind::ContextualMenu },

    { "copy", NativeCursorKind::DragCopy },
    { "dnd-copy", NativeCursorKind::DragCopy },

    { "alias", NativeCursorKind::DragLink },
    { "dnd-link", NativeCursorKind::DragLink },

    // No native equivalents; fall back to the arrow
    { "help", NativeCursorKind::Arrow },
    { "question_arrow", NativeCursorKind::Arrow },
    { "whats_this", NativeCursorKind::Arrow },
    { "wait", NativeCursorKind::Arrow },
    { "watch", NativeCursorKind::Arrow },
    { "progress", NativeCursorKind::Arrow },
    { "left_ptr_watch", NativeCursorKind::Arrow },
    { "half-busy", NativeCursorKind::Arrow },

    { "zoom-in", NativeCursorKind::ZoomIn },
    { "zoom-out", NativeCursorKind::ZoomOut },

    { "none", NativeCursorKind::Hidden },
};

static const char* kindName(NativeCursorKind kind)
{
    switch (kind) {
    case NativeCursorKind::Hidden: return "(hidden)";
    case NativeCursorKind::Arrow: return "arrowCursor";
    case NativeCursorKind::IBeam: return "IBeamCursor";
    case NativeCursorKind::IBeamVertical: return "IBeamCursorForVerticalLayout";
    case NativeCursorKind::PointingHand: return "pointingHandCursor";
    case NativeCursorKind::OpenHand: return "openHandCursor";
    case NativeCursorKind::ClosedHand: return "closedHandCursor";
    case NativeCursorKind::Crosshair: return "crosshairCursor";
    case NativeCursorKind::NotAllowed: return "operationNotAllowedCursor";
    case NativeCursorKind::ColumnResize: return "columnResizeCursor(all)";
    case NativeCursorKind::RowResize: return "rowResizeCursor(all)";
    case NativeCursorKind::FrameResizeEW: return "frameResizeCursor(Left, all)";
    case NativeCursorKind::FrameResizeNS: return "frameResizeCursor(Top, all)";
    case NativeCursorKind::FrameResizeE: return "frameResizeCursor(Right, outward)";
    case NativeCursorKind::FrameResizeW: return "frameResizeCursor(Left, outward)";
    case NativeCursorKind::FrameResizeN: return "frameResizeCursor(Top, outward)";
    case NativeCursorKind::FrameResizeS: return "frameResizeCursor(Bottom, outward)";
    case NativeCursorKind::FrameResizeNWSE: return "frameResizeCursor(TopLeft, all)";
    case NativeCursorKind::FrameResizeNESW: return "frameResizeCursor(TopRight, all)";
    case NativeCursorKind::FrameResizeNW: return "frameResizeCursor(TopLeft, outward)";
    case NativeCursorKind::FrameResizeSE: return "frameResizeCursor(BottomRight, outward)";
    case NativeCursorKind::FrameResizeNE: return "frameResizeCursor(TopRight, outward)";
    case NativeCursorKind::FrameResizeSW: return "frameResizeCursor(BottomLeft, outward)";
    case NativeCursorKind::ContextualMenu: return "contextualMenuCursor";
    case NativeCursorKind::DragCopy: return "dragCopyCursor";
    case NativeCursorKind::DragLink: return "dragLinkCursor";
    case NativeCursorKind::ZoomIn: return "zoomInCursor";
    case NativeCursorKind::ZoomOut: return "zoomOutCursor";
    case NativeCursorKind::Raster: return "NSCursor from host raster";
    }
    return "?";
}

static const char* formatName(uint8_t format)
{
    switch (format) {
    case LI_CURSOR_FORMAT_HIDDEN: return "HIDDEN";
    case LI_CURSOR_FORMAT_NAMED: return "NAMED";
    case LI_CURSOR_FORMAT_ARGB: return "ARGB";
    case LI_CURSOR_FORMAT_SVG: return "SVG";
    default: return "?";
    }
}

// How a host shape was resolved, for logging and the debug report
struct ShapeResolution {
    SDL_Cursor* cursor = nullptr;
    NSCursor* nsCursor = nil;          // The NSCursor shown (nil for SDL fallbacks or hidden)
    NativeCursorKind kind = NativeCursorKind::Hidden;
    QString mechanism;                 // How the cursor was produced
    QString note;                      // Anything unusual (unknown name, fallback, ...)
    CGFloat targetWidth = 0;           // Raster only: displayed size in points
    CGFloat targetHeight = 0;
};

// One row of the debug report: a distinct host shape and what it became
struct CursorReportEntry {
    CursorShapeMessage msg;
    QByteArray hostPng;
    QByteArray macPng;
    NSSize macImageSize = {0, 0};
    NSPoint macHotSpot = {0, 0};
    QString macCursor;
    QString mechanism;
    QString note;
    CGFloat targetWidth = 0;
    CGFloat targetHeight = 0;
    float pointerScale = 1.0f;
    int count = 0;
    qint64 firstSeenMs = 0;
};

class LocalCursorPrivate
{
public:
    LocalCursorPrivate()
        : m_Active(false),
          m_UseHostShape(true),
          m_NativeWrappingUnavailable(false),
          m_CurrentCursor(nullptr),
          m_RasterPointerScale(0.0f),
          m_SessionStartMs(QDateTime::currentMSecsSinceEpoch())
    {
    }

    ~LocalCursorPrivate()
    {
        writeReport();

        // Make sure SDL isn't referencing one of our cursors before freeing them
        SDL_SetCursor(SDL_GetDefaultCursor());
        m_CurrentCursor = nullptr;

        for (SDL_Cursor* cursor : std::as_const(m_NamedCursors)) {
            SDL_FreeCursor(cursor);
        }
        freeRasterCursors();
    }

    bool applyShape(const CursorShapeMessage& msg)
    {
        ShapeResolution res;

        switch (msg.format) {
        case LI_CURSOR_FORMAT_HIDDEN:
            res.mechanism = "hidden";
            break;

        case LI_CURSOR_FORMAT_NAMED:
            resolveName(msg.name, res);
            break;

        case LI_CURSOR_FORMAT_ARGB:
            resolveRaster(msg, res);
            if (res.cursor == nullptr) {
                // The host is not compositing a cursor, so show something
                SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                            "Unable to create cursor from %ux%u raster (%s). Falling back to arrow.",
                            msg.width, msg.height, qPrintable(msg.name));
                res.note = "invalid raster; fell back to arrow";
                resolveKind(NativeCursorKind::Arrow, res);
            }
            break;

        default:
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                        "Unsupported cursor shape format %u (%s). Falling back to arrow.",
                        msg.format, qPrintable(msg.name));
            res.note = QString("unsupported format %1; fell back to arrow").arg(msg.format);
            resolveKind(NativeCursorKind::Arrow, res);
            break;
        }

        recordShape(msg, res);

        m_CurrentCursor = res.cursor;
        m_Active = (res.cursor != nullptr);

        updateSdlCursor();

        return m_Active;
    }

    bool isActive() const
    {
        return m_Active;
    }

    void setUseHostShape(bool useHostShape)
    {
        if (m_UseHostShape != useHostShape) {
            m_UseHostShape = useHostShape;
            updateSdlCursor();
        }
    }

private:
    void updateSdlCursor()
    {
        if (m_UseHostShape && m_CurrentCursor != nullptr) {
            SDL_SetCursor(m_CurrentCursor);
        }
        else {
            SDL_SetCursor(SDL_GetDefaultCursor());
        }
    }

    void freeRasterCursors()
    {
        for (SDL_Cursor* cursor : std::as_const(m_RasterCursors)) {
            SDL_FreeCursor(cursor);
        }
        m_RasterCursors.clear();
    }

    // Wraps an NSCursor in an SDL_Cursor so SDL's cursor management can use it.
    // Returns nullptr (and leaves SDL untouched) if SDL's internals don't look
    // the way we expect.
    SDL_Cursor* wrapNativeCursor(NSCursor* nsCursor)
    {
        if (m_NativeWrappingUnavailable) {
            return nullptr;
        }

        SDL_Surface* dummySurface = SDL_CreateRGBSurfaceWithFormat(0, 1, 1, 32, SDL_PIXELFORMAT_ARGB8888);
        if (dummySurface == nullptr) {
            return nullptr;
        }

        SDL_Cursor* cursor = SDL_CreateColorCursor(dummySurface, 0, 0);
        SDL_FreeSurface(dummySurface);
        if (cursor == nullptr) {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                        "SDL_CreateColorCursor() failed: %s",
                        SDL_GetError());
            return nullptr;
        }

        void** slot = findNativeCursorSlot(cursor);
        if (slot == nullptr) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                         "Unable to locate NSCursor in SDL_Cursor. Falling back to SDL cursors for host cursor shapes.");
            SDL_FreeCursor(cursor);
            m_NativeWrappingUnavailable = true;
            return nullptr;
        }

        // SDL holds a +1 reference to its NSCursor and releases it in
        // SDL_FreeCursor(), so hand it ours with the same ownership.
        NSCursor* sdlNativeCursor = (NSCursor*)*slot;
        *slot = (void*)[nsCursor retain];
        [sdlNativeCursor release];

        return cursor;
    }

    // Fallback for when we can't wrap NSCursors: the closest SDL system cursor
    static SDL_Cursor* createSdlSystemCursor(NativeCursorKind kind, QString* description)
    {
        SDL_SystemCursor id;
        const char* name;
        switch (kind) {
        case NativeCursorKind::IBeam:
        case NativeCursorKind::IBeamVertical:
            id = SDL_SYSTEM_CURSOR_IBEAM; name = "SDL_SYSTEM_CURSOR_IBEAM";
            break;
        case NativeCursorKind::PointingHand:
            id = SDL_SYSTEM_CURSOR_HAND; name = "SDL_SYSTEM_CURSOR_HAND";
            break;
        case NativeCursorKind::OpenHand:
        case NativeCursorKind::ClosedHand:
            id = SDL_SYSTEM_CURSOR_SIZEALL; name = "SDL_SYSTEM_CURSOR_SIZEALL";
            break;
        case NativeCursorKind::Crosshair:
            id = SDL_SYSTEM_CURSOR_CROSSHAIR; name = "SDL_SYSTEM_CURSOR_CROSSHAIR";
            break;
        case NativeCursorKind::NotAllowed:
            id = SDL_SYSTEM_CURSOR_NO; name = "SDL_SYSTEM_CURSOR_NO";
            break;
        case NativeCursorKind::ColumnResize:
        case NativeCursorKind::FrameResizeEW:
        case NativeCursorKind::FrameResizeE:
        case NativeCursorKind::FrameResizeW:
            id = SDL_SYSTEM_CURSOR_SIZEWE; name = "SDL_SYSTEM_CURSOR_SIZEWE";
            break;
        case NativeCursorKind::RowResize:
        case NativeCursorKind::FrameResizeNS:
        case NativeCursorKind::FrameResizeN:
        case NativeCursorKind::FrameResizeS:
            id = SDL_SYSTEM_CURSOR_SIZENS; name = "SDL_SYSTEM_CURSOR_SIZENS";
            break;
        case NativeCursorKind::FrameResizeNWSE:
        case NativeCursorKind::FrameResizeNW:
        case NativeCursorKind::FrameResizeSE:
            id = SDL_SYSTEM_CURSOR_SIZENWSE; name = "SDL_SYSTEM_CURSOR_SIZENWSE";
            break;
        case NativeCursorKind::FrameResizeNESW:
        case NativeCursorKind::FrameResizeNE:
        case NativeCursorKind::FrameResizeSW:
            id = SDL_SYSTEM_CURSOR_SIZENESW; name = "SDL_SYSTEM_CURSOR_SIZENESW";
            break;
        default:
            id = SDL_SYSTEM_CURSOR_ARROW; name = "SDL_SYSTEM_CURSOR_ARROW";
            break;
        }
        *description = name;
        return SDL_CreateSystemCursor(id);
    }

    void resolveKind(NativeCursorKind kind, ShapeResolution& res)
    {
        res.kind = kind;
        if (kind == NativeCursorKind::Hidden) {
            res.cursor = nullptr;
            res.mechanism = "hidden";
            return;
        }

        // The NSCursor is reported even on cache hits so the report can render it
        res.nsCursor = nativeCursorForKind(kind);

        auto it = m_NamedCursors.find((int)kind);
        if (it != m_NamedCursors.end()) {
            res.cursor = it.value();
            res.mechanism = m_NamedCursorMechanisms.value((int)kind);
            return;
        }

        SDL_Cursor* cursor = wrapNativeCursor(res.nsCursor);
        if (cursor != nullptr) {
            res.mechanism = "native NSCursor";
        }
        else {
            QString sdlName;
            cursor = createSdlSystemCursor(kind, &sdlName);
            res.mechanism = "SDL system cursor fallback: " + sdlName;
            res.nsCursor = nil;
        }

        if (cursor != nullptr) {
            m_NamedCursors.insert((int)kind, cursor);
            m_NamedCursorMechanisms.insert((int)kind, res.mechanism);
        }
        res.cursor = cursor;
    }

    void resolveName(const QString& name, ShapeResolution& res)
    {
        QByteArray utf8 = name.toUtf8();
        for (const NamedCursorEntry& entry : k_NamedCursors) {
            if (utf8 == entry.name) {
                resolveKind(entry.kind, res);
                return;
            }
        }

        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                    "Unknown named cursor '%s'. Falling back to arrow.",
                    utf8.constData());
        res.note = "unknown name; fell back to arrow";
        resolveKind(NativeCursorKind::Arrow, res);
    }

    // macOS 15+ window-frame resize cursors. The @available guard only exists so
    // this compiles against the older deployment target; on older macOS the arrow
    // is shown. The enum types themselves are macOS 15 only, so the availability
    // warning is silenced for this helper and its callers below.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    static NSCursor* frameResizeCursor(NSCursorFrameResizePosition position, NSCursorFrameResizeDirections directions)
    {
        if (@available(macOS 15, *)) {
            return [NSCursor frameResizeCursorFromPosition:position inDirections:directions];
        }
        return [NSCursor arrowCursor];
    }

    static NSCursor* nativeCursorForKind(NativeCursorKind kind)
    {
        switch (kind) {
        case NativeCursorKind::IBeam:
            return [NSCursor IBeamCursor];
        case NativeCursorKind::IBeamVertical:
            return [NSCursor IBeamCursorForVerticalLayout];
        case NativeCursorKind::PointingHand:
            return [NSCursor pointingHandCursor];
        case NativeCursorKind::OpenHand:
            return [NSCursor openHandCursor];
        case NativeCursorKind::ClosedHand:
            return [NSCursor closedHandCursor];
        case NativeCursorKind::Crosshair:
            return [NSCursor crosshairCursor];
        case NativeCursorKind::NotAllowed:
            return [NSCursor operationNotAllowedCursor];
        case NativeCursorKind::ColumnResize:
            if (@available(macOS 15, *)) {
                return [NSCursor columnResizeCursorInDirections:NSHorizontalDirectionsAll];
            }
            return [NSCursor resizeLeftRightCursor];
        case NativeCursorKind::RowResize:
            if (@available(macOS 15, *)) {
                return [NSCursor rowResizeCursorInDirections:NSVerticalDirectionsAll];
            }
            return [NSCursor resizeUpDownCursor];
        case NativeCursorKind::FrameResizeEW:
            return frameResizeCursor(NSCursorFrameResizePositionLeft, NSCursorFrameResizeDirectionsAll);
        case NativeCursorKind::FrameResizeNS:
            return frameResizeCursor(NSCursorFrameResizePositionTop, NSCursorFrameResizeDirectionsAll);
        case NativeCursorKind::FrameResizeE:
            return frameResizeCursor(NSCursorFrameResizePositionRight, NSCursorFrameResizeDirectionsOutward);
        case NativeCursorKind::FrameResizeW:
            return frameResizeCursor(NSCursorFrameResizePositionLeft, NSCursorFrameResizeDirectionsOutward);
        case NativeCursorKind::FrameResizeN:
            return frameResizeCursor(NSCursorFrameResizePositionTop, NSCursorFrameResizeDirectionsOutward);
        case NativeCursorKind::FrameResizeS:
            return frameResizeCursor(NSCursorFrameResizePositionBottom, NSCursorFrameResizeDirectionsOutward);
        case NativeCursorKind::FrameResizeNWSE:
            return frameResizeCursor(NSCursorFrameResizePositionTopLeft, NSCursorFrameResizeDirectionsAll);
        case NativeCursorKind::FrameResizeNESW:
            return frameResizeCursor(NSCursorFrameResizePositionTopRight, NSCursorFrameResizeDirectionsAll);
        case NativeCursorKind::FrameResizeNW:
            return frameResizeCursor(NSCursorFrameResizePositionTopLeft, NSCursorFrameResizeDirectionsOutward);
        case NativeCursorKind::FrameResizeSE:
            return frameResizeCursor(NSCursorFrameResizePositionBottomRight, NSCursorFrameResizeDirectionsOutward);
        case NativeCursorKind::FrameResizeNE:
            return frameResizeCursor(NSCursorFrameResizePositionTopRight, NSCursorFrameResizeDirectionsOutward);
        case NativeCursorKind::FrameResizeSW:
            return frameResizeCursor(NSCursorFrameResizePositionBottomLeft, NSCursorFrameResizeDirectionsOutward);
        case NativeCursorKind::ContextualMenu:
            return [NSCursor contextualMenuCursor];
        case NativeCursorKind::DragCopy:
            return [NSCursor dragCopyCursor];
        case NativeCursorKind::DragLink:
            return [NSCursor dragLinkCursor];
        case NativeCursorKind::ZoomIn:
            if (@available(macOS 15, *)) {
                return [NSCursor zoomInCursor];
            }
            return [NSCursor arrowCursor];
        case NativeCursorKind::ZoomOut:
            if (@available(macOS 15, *)) {
                return [NSCursor zoomOutCursor];
            }
            return [NSCursor arrowCursor];
        case NativeCursorKind::Arrow:
        case NativeCursorKind::Hidden:
        case NativeCursorKind::Raster:
        default:
            return [NSCursor arrowCursor];
        }
    }
#pragma clang diagnostic pop

    // The user's Accessibility > Display > Pointer size setting (1.0 - 4.0).
    // System cursors honor this automatically, but custom NSCursors do not,
    // so we must scale our raster cursors ourselves.
    static float getPointerScale()
    {
        NSUserDefaults* defaults = [[[NSUserDefaults alloc] initWithSuiteName:@"com.apple.universalaccess"] autorelease];
        float scale = [defaults floatForKey:@"mouseDriverCursorSize"];
        if (!(scale >= 1.0f && scale <= 4.0f)) {
            scale = 1.0f;
        }
        return scale;
    }

    static float getPointsPerNominalPixel()
    {
        bool ok = false;
        float value = qEnvironmentVariable("LOCAL_CURSOR_SCALE").toFloat(&ok);
        if (ok && value > 0.0f && value <= 8.0f) {
            return value;
        }
        return DEFAULT_POINTS_PER_NOMINAL_PIXEL;
    }

    static QByteArray rasterCacheKey(const CursorShapeMessage& msg)
    {
        QByteArray key;
        key.append((const char*)&msg.width, sizeof(msg.width));
        key.append((const char*)&msg.height, sizeof(msg.height));
        key.append((const char*)&msg.hotX, sizeof(msg.hotX));
        key.append((const char*)&msg.hotY, sizeof(msg.hotY));
        key.append((const char*)&msg.nominalSize, sizeof(msg.nominalSize));
        size_t dataHash = qHash(msg.data);
        key.append((const char*)&dataHash, sizeof(dataHash));
        return key;
    }

    void resolveRaster(const CursorShapeMessage& msg, ShapeResolution& res)
    {
        res.kind = NativeCursorKind::Raster;

        if (msg.width == 0 || msg.height == 0 ||
                msg.data.size() != (int)msg.width * msg.height * 4) {
            return;
        }

        // Custom cursors are scaled by us, so flush the cache if the pointer size changed
        float pointerScale = getPointerScale();
        if (pointerScale != m_RasterPointerScale) {
            freeRasterCursors();
            m_RasterPointerScale = pointerScale;
        }

        getTargetPointSize(msg, pointerScale, &res.targetWidth, &res.targetHeight);

        QByteArray key = rasterCacheKey(msg);
        auto it = m_RasterCursors.find(key);
        if (it != m_RasterCursors.end()) {
            res.cursor = it.value();
            res.mechanism = m_RasterCursorMechanisms.value(key);
            return;
        }

        SDL_Cursor* cursor = nullptr;
        if (!m_NativeWrappingUnavailable) {
            NSCursor* nsCursor = createRasterCursor(msg, pointerScale);
            if (nsCursor != nil) {
                cursor = wrapNativeCursor(nsCursor);
                if (cursor != nullptr) {
                    res.nsCursor = [nsCursor autorelease];
                    res.mechanism = "native NSCursor from host raster";
                }
                else {
                    [nsCursor release];
                }
            }
        }
        if (cursor == nullptr) {
            cursor = createSdlRasterCursor(msg, pointerScale);
            res.mechanism = "SDL color cursor fallback (1x)";
        }
        if (cursor != nullptr) {
            m_RasterCursors.insert(key, cursor);
            m_RasterCursorMechanisms.insert(key, res.mechanism);
        }
        res.cursor = cursor;
    }

    // Computes the point size a host raster should be displayed at. The raster
    // represents a nominalSize-pixel box on the host regardless of its actual
    // resolution (hosts send the largest size they have).
    static void getTargetPointSize(const CursorShapeMessage& msg, float pointerScale, CGFloat* targetWidth, CGFloat* targetHeight)
    {
        float nominalSize = msg.nominalSize != 0 ? msg.nominalSize : msg.width;
        *targetWidth = nominalSize * getPointsPerNominalPixel() * pointerScale;
        *targetHeight = *targetWidth * msg.height / msg.width;
    }

    static CGImageRef createSourceImage(const CursorShapeMessage& msg, CGColorSpaceRef colorSpace)
    {
        CGDataProviderRef provider = CGDataProviderCreateWithData(nullptr, msg.data.constData(), msg.data.size(), nullptr);
        CGImageRef sourceImage = CGImageCreate(msg.width, msg.height, 8, 32, msg.width * 4, colorSpace,
                                               kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                                               provider, nullptr, true, kCGRenderingIntentDefault);
        CGDataProviderRelease(provider);
        return sourceImage;
    }

    // Scales the source image into a new premultiplied BGRA bitmap context
    static CGContextRef createScaledBitmap(CGImageRef sourceImage, CGColorSpaceRef colorSpace, size_t pixelWidth, size_t pixelHeight)
    {
        CGContextRef context = CGBitmapContextCreate(nullptr, pixelWidth, pixelHeight, 8, 0, colorSpace,
                                                     kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        if (context != nullptr) {
            CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
            CGContextDrawImage(context, CGRectMake(0, 0, pixelWidth, pixelHeight), sourceImage);
        }
        return context;
    }

    // Fallback for when we can't wrap NSCursors: a 1x SDL color cursor
    static SDL_Cursor* createSdlRasterCursor(const CursorShapeMessage& msg, float pointerScale)
    {
        CGFloat targetWidth, targetHeight;
        getTargetPointSize(msg, pointerScale, &targetWidth, &targetHeight);
        size_t pixelWidth = (size_t)std::ceil(targetWidth);
        size_t pixelHeight = (size_t)std::ceil(targetHeight);

        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGImageRef sourceImage = createSourceImage(msg, colorSpace);
        CGContextRef context = sourceImage != nullptr ? createScaledBitmap(sourceImage, colorSpace, pixelWidth, pixelHeight) : nullptr;
        SDL_Cursor* cursor = nullptr;

        if (context != nullptr) {
            SDL_Surface* surface = SDL_CreateRGBSurfaceWithFormatFrom(CGBitmapContextGetData(context),
                                                                      (int)pixelWidth, (int)pixelHeight, 32,
                                                                      (int)CGBitmapContextGetBytesPerRow(context),
                                                                      SDL_PIXELFORMAT_ARGB8888);
            if (surface != nullptr) {
                cursor = SDL_CreateColorCursor(surface,
                                               (int)(msg.hotX * targetWidth / msg.width),
                                               (int)(msg.hotY * targetHeight / msg.height));
                SDL_FreeSurface(surface);
            }
            CGContextRelease(context);
        }

        if (sourceImage != nullptr) {
            CGImageRelease(sourceImage);
        }
        CGColorSpaceRelease(colorSpace);
        return cursor;
    }

    // Builds a Retina-aware NSCursor from a premultiplied BGRA raster, scaled
    // so the cursor's nominal box maps to the same point size as a system
    // cursor at the user's pointer size. Returns a +1 retained cursor.
    static NSCursor* createRasterCursor(const CursorShapeMessage& msg, float pointerScale)
    {
        CGFloat targetWidth, targetHeight;
        getTargetPointSize(msg, pointerScale, &targetWidth, &targetHeight);
        CGFloat scaleToPoints = targetWidth / msg.width;

        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGImageRef sourceImage = createSourceImage(msg, colorSpace);
        if (sourceImage == nullptr) {
            CGColorSpaceRelease(colorSpace);
            return nil;
        }

        // Add one representation per backing scale present so the cursor
        // stays sharp on whichever display the window lands on.
        QSet<int> backingScales;
        for (NSScreen* screen in [NSScreen screens]) {
            backingScales.insert((int)std::lround(screen.backingScaleFactor));
        }
        if (backingScales.isEmpty()) {
            backingScales.insert(1);
        }

        NSImage* image = [[[NSImage alloc] initWithSize:NSMakeSize(targetWidth, targetHeight)] autorelease];
        for (int backingScale : std::as_const(backingScales)) {
            size_t pixelWidth = (size_t)std::ceil(targetWidth * backingScale);
            size_t pixelHeight = (size_t)std::ceil(targetHeight * backingScale);

            CGContextRef context = createScaledBitmap(sourceImage, colorSpace, pixelWidth, pixelHeight);
            if (context == nullptr) {
                continue;
            }

            CGImageRef scaledImage = CGBitmapContextCreateImage(context);
            CGContextRelease(context);
            if (scaledImage == nullptr) {
                continue;
            }

            NSBitmapImageRep* rep = [[[NSBitmapImageRep alloc] initWithCGImage:scaledImage] autorelease];
            CGImageRelease(scaledImage);

            // The rep's point size determines which backing scale it is used for
            rep.size = NSMakeSize(targetWidth, targetHeight);
            [image addRepresentation:rep];
        }

        CGImageRelease(sourceImage);
        CGColorSpaceRelease(colorSpace);

        if (image.representations.count == 0) {
            return nil;
        }

        NSPoint hotSpot = NSMakePoint(msg.hotX * scaleToPoints, msg.hotY * scaleToPoints);
        return [[NSCursor alloc] initWithImage:image hotSpot:hotSpot];
    }

    // ---- Debug report -----------------------------------------------------

    static QByteArray reportKey(const CursorShapeMessage& msg)
    {
        QByteArray key;
        key.append((char)msg.format);
        key.append(msg.name.toUtf8());
        key.append('\0');
        if (msg.format == LI_CURSOR_FORMAT_ARGB) {
            key.append(rasterCacheKey(msg));
        }
        return key;
    }

    // Renders an NSImage to PNG at 2x for the report
    static QByteArray pngFromNSImage(NSImage* image)
    {
        if (image == nil || image.size.width <= 0 || image.size.height <= 0) {
            return QByteArray();
        }

        const int scale = 2;
        NSBitmapImageRep* rep = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr
                                                                          pixelsWide:(NSInteger)std::ceil(image.size.width * scale)
                                                                          pixelsHigh:(NSInteger)std::ceil(image.size.height * scale)
                                                                       bitsPerSample:8
                                                                     samplesPerPixel:4
                                                                            hasAlpha:YES
                                                                            isPlanar:NO
                                                                      colorSpaceName:NSDeviceRGBColorSpace
                                                                         bytesPerRow:0
                                                                        bitsPerPixel:0] autorelease];
        if (rep == nil) {
            return QByteArray();
        }
        rep.size = image.size;

        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
        [image drawInRect:NSMakeRect(0, 0, image.size.width, image.size.height)
                 fromRect:NSZeroRect
                operation:NSCompositingOperationCopy
                 fraction:1.0];
        [NSGraphicsContext restoreGraphicsState];

        NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        return QByteArray((const char*)png.bytes, (int)png.length);
    }

    static QByteArray pngFromHostRaster(const CursorShapeMessage& msg)
    {
        if (msg.format != LI_CURSOR_FORMAT_ARGB || msg.width == 0 || msg.height == 0 ||
                msg.data.size() != (int)msg.width * msg.height * 4) {
            return QByteArray();
        }

        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGImageRef image = createSourceImage(msg, colorSpace);
        CGColorSpaceRelease(colorSpace);
        if (image == nullptr) {
            return QByteArray();
        }

        NSBitmapImageRep* rep = [[[NSBitmapImageRep alloc] initWithCGImage:image] autorelease];
        CGImageRelease(image);
        NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        return QByteArray((const char*)png.bytes, (int)png.length);
    }

    void recordShape(const CursorShapeMessage& msg, const ShapeResolution& res)
    {
        QByteArray key = reportKey(msg);
        auto it = m_ReportIndex.find(key);
        if (it != m_ReportIndex.end()) {
            m_Report[it.value()].count++;
            return;
        }

        CursorReportEntry entry;
        entry.msg = msg;
        entry.count = 1;
        entry.firstSeenMs = QDateTime::currentMSecsSinceEpoch() - m_SessionStartMs;
        entry.macCursor = res.cursor != nullptr ? kindName(res.kind) : kindName(NativeCursorKind::Hidden);
        entry.mechanism = res.mechanism;
        entry.note = res.note;
        entry.targetWidth = res.targetWidth;
        entry.targetHeight = res.targetHeight;
        entry.pointerScale = m_RasterPointerScale != 0.0f ? m_RasterPointerScale : getPointerScale();
        entry.hostPng = pngFromHostRaster(msg);
        if (res.nsCursor != nil) {
            entry.macPng = pngFromNSImage(res.nsCursor.image);
            entry.macImageSize = res.nsCursor.image.size;
            entry.macHotSpot = res.nsCursor.hotSpot;
        }

        m_ReportIndex.insert(key, m_Report.size());
        m_Report.append(entry);
    }

    static QString htmlEscape(const QString& s)
    {
        return s.toHtmlEscaped();
    }

    static QString imgTag(const QByteArray& png, double widthPts, double heightPts, const QString& alt)
    {
        if (png.isEmpty()) {
            return "<span class=\"none\">" + alt + "</span>";
        }
        QString style;
        if (widthPts > 0 && heightPts > 0) {
            style = QString(" style=\"width:%1px;height:%2px\"").arg(widthPts).arg(heightPts);
        }
        return QString("<img src=\"data:image/png;base64,%1\"%2 alt=\"%3\">")
                .arg(QString::fromLatin1(png.toBase64()), style, alt);
    }

    void writeReport()
    { @autoreleasepool {
        if (m_Report.isEmpty()) {
            return;
        }

        if (qEnvironmentVariable("LOCAL_CURSOR_REPORT") == "0") {
            return;
        }

        QDir logDir(Path::getLogDir());
        QString path = logDir.filePath(QString("Moonlight-cursors-%1.html").arg(QDateTime::currentSecsSinceEpoch()));

        SDL_version sdlVersion;
        SDL_GetVersion(&sdlVersion);

        QString html;
        html += "<!doctype html><html><head><meta charset=\"utf-8\"><title>Moonlight cursor shapes</title>\n";
        html += "<style>\n"
                "body{font:14px -apple-system,Helvetica,sans-serif;margin:24px;color:#222;background:#fafafa}\n"
                "h1{font-size:20px;margin:0 0 4px} .meta{color:#666;margin-bottom:16px}\n"
                "table{border-collapse:collapse;width:100%;background:#fff}\n"
                "th,td{border:1px solid #ddd;padding:8px 10px;text-align:left;vertical-align:top}\n"
                "th{background:#f0f0f0;font-weight:600}\n"
                "td.img{background:repeating-conic-gradient(#e6e6e6 0 25%,#fff 0 50%) 0 0/16px 16px;text-align:center;vertical-align:middle}\n"
                "code{font:12px Menlo,monospace;background:#f3f3f3;padding:1px 4px;border-radius:3px}\n"
                ".none{color:#999;font-style:italic} .note{color:#b3261e} .small{color:#666;font-size:12px}\n"
                "img{vertical-align:middle;image-rendering:auto}\n"
                "</style></head><body>\n";
        html += "<h1>Moonlight cursor shapes</h1>\n";
        html += QString("<div class=\"meta\">%1 &middot; %2 distinct shape%3 &middot; pointer scale %4 &middot; "
                        "points per nominal px %5 &middot; SDL %6.%7.%8%9</div>\n")
                .arg(htmlEscape(QDateTime::currentDateTime().toString(Qt::ISODate)))
                .arg(m_Report.size())
                .arg(m_Report.size() == 1 ? "" : "s")
                .arg(getPointerScale())
                .arg(getPointsPerNominalPixel())
                .arg(sdlVersion.major).arg(sdlVersion.minor).arg(sdlVersion.patch)
                .arg(m_NativeWrappingUnavailable ? " &middot; <span class=\"note\">NSCursor wrapping unavailable; SDL fallbacks in use</span>" : "");

        html += "<table><thead><tr>"
                "<th>#</th><th>Linux name</th><th>Format</th><th>Host image</th><th>Host details</th>"
                "<th>Mac cursor</th><th>Mac image (as shown)</th><th>Mac details</th><th>Count</th><th>First seen</th>"
                "</tr></thead><tbody>\n";

        int row = 0;
        for (const CursorReportEntry& e : std::as_const(m_Report)) {
            row++;
            const CursorShapeMessage& m = e.msg;

            QString hostDetails;
            if (m.format == LI_CURSOR_FORMAT_ARGB) {
                hostDetails = QString("%1&times;%2 px, hotspot (%3,%4), nominal %5 px, %6 bytes")
                        .arg(m.width).arg(m.height).arg(m.hotX).arg(m.hotY).arg(m.nominalSize).arg(m.data.size());
            }
            else if (m.format == LI_CURSOR_FORMAT_NAMED) {
                hostDetails = QString("nominal %1 px").arg(m.nominalSize);
            }

            QString macDetails;
            if (!e.mechanism.isEmpty()) {
                macDetails += htmlEscape(e.mechanism);
            }
            if (e.targetWidth > 0) {
                macDetails += QString("<br>displayed at %1&times;%2 pt (pointer scale %3)")
                        .arg(e.targetWidth, 0, 'f', 1).arg(e.targetHeight, 0, 'f', 1).arg(e.pointerScale);
            }
            if (!e.macPng.isEmpty()) {
                macDetails += QString("<br><span class=\"small\">image %1&times;%2 pt, hotspot (%3,%4)</span>")
                        .arg(e.macImageSize.width, 0, 'f', 1).arg(e.macImageSize.height, 0, 'f', 1)
                        .arg(e.macHotSpot.x, 0, 'f', 1).arg(e.macHotSpot.y, 0, 'f', 1);
            }
            if (!e.note.isEmpty()) {
                macDetails += "<br><span class=\"note\">" + htmlEscape(e.note) + "</span>";
            }

            // Show the host raster at its native pixel size (1 px = 1 CSS px) and the
            // Mac image at its point size, so relative sizes are comparable on screen.
            html += QString("<tr><td>%1</td><td><code>%2</code></td><td>%3</td>"
                            "<td class=\"img\">%4</td><td>%5</td>"
                            "<td><code>%6</code></td><td class=\"img\">%7</td><td>%8</td>"
                            "<td>%9</td><td>%10 s</td></tr>\n")
                    .arg(row)
                    .arg(m.name.isEmpty() ? QString("<span class=\"none\">(unnamed)</span>") : htmlEscape(m.name))
                    .arg(formatName(m.format))
                    .arg(imgTag(e.hostPng, m.width, m.height, m.format == LI_CURSOR_FORMAT_ARGB ? "host raster" : "&ndash;"))
                    .arg(hostDetails)
                    .arg(htmlEscape(e.macCursor))
                    .arg(imgTag(e.macPng, e.macImageSize.width, e.macImageSize.height, e.mechanism.startsWith("SDL") ? "SDL cursor (no preview)" : "&ndash;"))
                    .arg(macDetails)
                    .arg(e.count)
                    .arg(e.firstSeenMs / 1000.0, 0, 'f', 1);
        }

        html += "</tbody></table>\n</body></html>\n";

        QFile file(path);
        if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                        "Unable to write cursor shape report to %s",
                        qPrintable(path));
            return;
        }
        file.write(html.toUtf8());
        file.close();

        SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                    "Wrote cursor shape report with %d shapes to %s",
                    (int)m_Report.size(),
                    qPrintable(path));

        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path.toNSString()]];
    }}

    bool m_Active;
    bool m_UseHostShape;
    bool m_NativeWrappingUnavailable;
    SDL_Cursor* m_CurrentCursor;
    float m_RasterPointerScale;
    QHash<int, SDL_Cursor*> m_NamedCursors;
    QHash<int, QString> m_NamedCursorMechanisms;
    QHash<QByteArray, SDL_Cursor*> m_RasterCursors;
    QHash<QByteArray, QString> m_RasterCursorMechanisms;

    qint64 m_SessionStartMs;
    QList<CursorReportEntry> m_Report;
    QHash<QByteArray, int> m_ReportIndex;
};

LocalCursor::LocalCursor()
    : m_Private(new LocalCursorPrivate())
{
}

LocalCursor::~LocalCursor()
{ @autoreleasepool {
    delete m_Private;
}}

bool LocalCursor::applyShape(const CursorShapeMessage& msg)
{ @autoreleasepool {
    return m_Private->applyShape(msg);
}}

bool LocalCursor::isActive() const
{
    return m_Private->isActive();
}

void LocalCursor::setUseHostShape(bool useHostShape)
{ @autoreleasepool {
    m_Private->setUseHostShape(useHostShape);
}}
