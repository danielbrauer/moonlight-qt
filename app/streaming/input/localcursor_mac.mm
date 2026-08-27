#include "localcursor.h"

#include "SDL_compat.h"
#include <Limelight.h>

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

#include <QHash>
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
    ResizeLeftRight,
    ResizeUpDown,
    ResizeLeft,
    ResizeRight,
    ResizeUp,
    ResizeDown,
    ResizeNwSe,
    ResizeNeSw,
    ContextualMenu,
    DragCopy,
    DragLink,
    ZoomIn,
    ZoomOut,
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

    { "col-resize", NativeCursorKind::ResizeLeftRight },
    { "ew-resize", NativeCursorKind::ResizeLeftRight },
    { "sb_h_double_arrow", NativeCursorKind::ResizeLeftRight },
    { "h_double_arrow", NativeCursorKind::ResizeLeftRight },
    { "size_hor", NativeCursorKind::ResizeLeftRight },
    { "split_h", NativeCursorKind::ResizeLeftRight },

    { "row-resize", NativeCursorKind::ResizeUpDown },
    { "ns-resize", NativeCursorKind::ResizeUpDown },
    { "sb_v_double_arrow", NativeCursorKind::ResizeUpDown },
    { "v_double_arrow", NativeCursorKind::ResizeUpDown },
    { "size_ver", NativeCursorKind::ResizeUpDown },
    { "split_v", NativeCursorKind::ResizeUpDown },

    { "e-resize", NativeCursorKind::ResizeRight },
    { "right_side", NativeCursorKind::ResizeRight },
    { "right_arrow", NativeCursorKind::ResizeRight },

    { "w-resize", NativeCursorKind::ResizeLeft },
    { "left_side", NativeCursorKind::ResizeLeft },
    { "left_arrow", NativeCursorKind::ResizeLeft },

    { "n-resize", NativeCursorKind::ResizeUp },
    { "top_side", NativeCursorKind::ResizeUp },
    { "up_arrow", NativeCursorKind::ResizeUp },

    { "s-resize", NativeCursorKind::ResizeDown },
    { "bottom_side", NativeCursorKind::ResizeDown },
    { "down_arrow", NativeCursorKind::ResizeDown },

    { "nwse-resize", NativeCursorKind::ResizeNwSe },
    { "nw-resize", NativeCursorKind::ResizeNwSe },
    { "se-resize", NativeCursorKind::ResizeNwSe },
    { "size_fdiag", NativeCursorKind::ResizeNwSe },
    { "top_left_corner", NativeCursorKind::ResizeNwSe },
    { "bottom_right_corner", NativeCursorKind::ResizeNwSe },

    { "nesw-resize", NativeCursorKind::ResizeNeSw },
    { "ne-resize", NativeCursorKind::ResizeNeSw },
    { "sw-resize", NativeCursorKind::ResizeNeSw },
    { "size_bdiag", NativeCursorKind::ResizeNeSw },
    { "top_right_corner", NativeCursorKind::ResizeNeSw },
    { "bottom_left_corner", NativeCursorKind::ResizeNeSw },

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

class LocalCursorPrivate
{
public:
    LocalCursorPrivate()
        : m_Active(false),
          m_UseHostShape(true),
          m_NativeWrappingUnavailable(false),
          m_CurrentCursor(nullptr),
          m_RasterPointerScale(0.0f)
    {
    }

    ~LocalCursorPrivate()
    {
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
        SDL_Cursor* cursor = nullptr;

        switch (msg.format) {
        case LI_CURSOR_FORMAT_HIDDEN:
            break;

        case LI_CURSOR_FORMAT_NAMED:
            cursor = cursorForName(msg.name);
            break;

        case LI_CURSOR_FORMAT_ARGB:
            cursor = cursorForRaster(msg);
            if (cursor == nullptr) {
                // The host is not compositing a cursor, so show something
                SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                            "Unable to create cursor from %ux%u raster (%s). Falling back to arrow.",
                            msg.width, msg.height, qPrintable(msg.name));
                cursor = cursorForKind(NativeCursorKind::Arrow);
            }
            break;

        default:
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                        "Unsupported cursor shape format %u (%s). Falling back to arrow.",
                        msg.format, qPrintable(msg.name));
            cursor = cursorForKind(NativeCursorKind::Arrow);
            break;
        }

        m_CurrentCursor = cursor;
        m_Active = (cursor != nullptr);

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
    static SDL_Cursor* createSdlSystemCursor(NativeCursorKind kind)
    {
        SDL_SystemCursor id;
        switch (kind) {
        case NativeCursorKind::IBeam:
        case NativeCursorKind::IBeamVertical:
            id = SDL_SYSTEM_CURSOR_IBEAM;
            break;
        case NativeCursorKind::PointingHand:
            id = SDL_SYSTEM_CURSOR_HAND;
            break;
        case NativeCursorKind::OpenHand:
        case NativeCursorKind::ClosedHand:
            id = SDL_SYSTEM_CURSOR_SIZEALL;
            break;
        case NativeCursorKind::Crosshair:
            id = SDL_SYSTEM_CURSOR_CROSSHAIR;
            break;
        case NativeCursorKind::NotAllowed:
            id = SDL_SYSTEM_CURSOR_NO;
            break;
        case NativeCursorKind::ResizeLeftRight:
        case NativeCursorKind::ResizeLeft:
        case NativeCursorKind::ResizeRight:
            id = SDL_SYSTEM_CURSOR_SIZEWE;
            break;
        case NativeCursorKind::ResizeUpDown:
        case NativeCursorKind::ResizeUp:
        case NativeCursorKind::ResizeDown:
            id = SDL_SYSTEM_CURSOR_SIZENS;
            break;
        case NativeCursorKind::ResizeNwSe:
            id = SDL_SYSTEM_CURSOR_SIZENWSE;
            break;
        case NativeCursorKind::ResizeNeSw:
            id = SDL_SYSTEM_CURSOR_SIZENESW;
            break;
        default:
            id = SDL_SYSTEM_CURSOR_ARROW;
            break;
        }
        return SDL_CreateSystemCursor(id);
    }

    SDL_Cursor* cursorForKind(NativeCursorKind kind)
    {
        if (kind == NativeCursorKind::Hidden) {
            return nullptr;
        }

        auto it = m_NamedCursors.find((int)kind);
        if (it != m_NamedCursors.end()) {
            return it.value();
        }

        NSCursor* nsCursor = nativeCursorForKind(kind);
        SDL_Cursor* cursor = wrapNativeCursor(nsCursor);
        if (cursor == nullptr) {
            cursor = createSdlSystemCursor(kind);
        }
        if (cursor != nullptr) {
            m_NamedCursors.insert((int)kind, cursor);
        }
        return cursor;
    }

    SDL_Cursor* cursorForName(const QString& name)
    {
        QByteArray utf8 = name.toUtf8();
        for (const NamedCursorEntry& entry : k_NamedCursors) {
            if (utf8 == entry.name) {
                return cursorForKind(entry.kind);
            }
        }

        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                    "Unknown named cursor '%s'. Falling back to arrow.",
                    utf8.constData());
        return cursorForKind(NativeCursorKind::Arrow);
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
        case NativeCursorKind::ResizeLeftRight:
            return [NSCursor resizeLeftRightCursor];
        case NativeCursorKind::ResizeUpDown:
            return [NSCursor resizeUpDownCursor];
        case NativeCursorKind::ResizeLeft:
            return [NSCursor resizeLeftCursor];
        case NativeCursorKind::ResizeRight:
            return [NSCursor resizeRightCursor];
        case NativeCursorKind::ResizeUp:
            return [NSCursor resizeUpCursor];
        case NativeCursorKind::ResizeDown:
            return [NSCursor resizeDownCursor];
        case NativeCursorKind::ResizeNwSe:
            if (@available(macOS 15, *)) {
                return [NSCursor frameResizeCursorFromPosition:NSCursorFrameResizePositionTopLeft
                                                  inDirections:NSCursorFrameResizeDirectionsAll];
            }
            return [NSCursor arrowCursor];
        case NativeCursorKind::ResizeNeSw:
            if (@available(macOS 15, *)) {
                return [NSCursor frameResizeCursorFromPosition:NSCursorFrameResizePositionTopRight
                                                  inDirections:NSCursorFrameResizeDirectionsAll];
            }
            return [NSCursor arrowCursor];
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
        default:
            return [NSCursor arrowCursor];
        }
    }

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

    SDL_Cursor* cursorForRaster(const CursorShapeMessage& msg)
    {
        if (msg.width == 0 || msg.height == 0 ||
                msg.data.size() != (int)msg.width * msg.height * 4) {
            return nullptr;
        }

        // Custom cursors are scaled by us, so flush the cache if the pointer size changed
        float pointerScale = getPointerScale();
        if (pointerScale != m_RasterPointerScale) {
            freeRasterCursors();
            m_RasterPointerScale = pointerScale;
        }

        // Cache by image content and hotspot
        QByteArray key;
        key.append((const char*)&msg.width, sizeof(msg.width));
        key.append((const char*)&msg.height, sizeof(msg.height));
        key.append((const char*)&msg.hotX, sizeof(msg.hotX));
        key.append((const char*)&msg.hotY, sizeof(msg.hotY));
        key.append((const char*)&msg.nominalSize, sizeof(msg.nominalSize));
        size_t dataHash = qHash(msg.data);
        key.append((const char*)&dataHash, sizeof(dataHash));

        auto it = m_RasterCursors.find(key);
        if (it != m_RasterCursors.end()) {
            return it.value();
        }

        SDL_Cursor* cursor = nullptr;
        if (!m_NativeWrappingUnavailable) {
            NSCursor* nsCursor = createRasterCursor(msg, pointerScale);
            if (nsCursor != nil) {
                cursor = wrapNativeCursor(nsCursor);
                [nsCursor release];
            }
        }
        if (cursor == nullptr) {
            cursor = createSdlRasterCursor(msg, pointerScale);
        }
        if (cursor != nullptr) {
            m_RasterCursors.insert(key, cursor);
        }
        return cursor;
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

    bool m_Active;
    bool m_UseHostShape;
    bool m_NativeWrappingUnavailable;
    SDL_Cursor* m_CurrentCursor;
    float m_RasterPointerScale;
    QHash<int, SDL_Cursor*> m_NamedCursors;
    QHash<QByteArray, SDL_Cursor*> m_RasterCursors;
};

LocalCursor::LocalCursor()
    : m_Private(new LocalCursorPrivate())
{
}

LocalCursor::~LocalCursor()
{
    delete m_Private;
}

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
