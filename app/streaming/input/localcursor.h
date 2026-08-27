#pragma once

#include <QByteArray>
#include <QString>

#include <cstdint>

// A cursor shape message received from the host.
// See ConnListenerSetCursorShape in Limelight.h for field semantics.
struct CursorShapeMessage {
    uint8_t format;       // LI_CURSOR_FORMAT_*
    QString name;         // Empty if unnamed
    uint16_t width;
    uint16_t height;
    uint16_t hotX;
    uint16_t hotY;
    uint16_t nominalSize;
    QByteArray data;      // Image data for LI_CURSOR_FORMAT_ARGB
};

class LocalCursorPrivate;

// Renders host-provided cursor shapes as a native local cursor.
//
// All methods must be called on the main (SDL event) thread.
// On platforms without an implementation, applyShape() always returns false.
class LocalCursor
{
public:
    LocalCursor();
    ~LocalCursor();

    // Applies a cursor shape from the host. Returns true if a host cursor
    // shape is now active and the local cursor should be displayed, or
    // false if the host asked for the cursor to be hidden (or this platform
    // cannot render host cursor shapes).
    bool applyShape(const CursorShapeMessage& msg);

    // Returns true if a host cursor shape is currently active
    bool isActive() const;

    // Sets the scale at which host pixels are displayed on screen (points per
    // host pixel), so raster cursors can be shown at the size they would have
    // had if the host had composited them into the video.
    void setVideoScale(double pointsPerHostPixel);

    // Selects the host-provided shape (true) or the system default cursor
    // (false) as the current SDL cursor. This is used to show the normal
    // cursor when the pointer is outside the video region.
    void setUseHostShape(bool useHostShape);

private:
    LocalCursorPrivate* m_Private;
};
