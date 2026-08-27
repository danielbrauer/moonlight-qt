#include "localcursor.h"

// Platforms without native cursor shape support. The host will only stop
// compositing its cursor if we advertise local cursor support, which
// Session only does on platforms with a real implementation.

class LocalCursorPrivate {};

LocalCursor::LocalCursor()
    : m_Private(nullptr)
{
}

LocalCursor::~LocalCursor()
{
}

bool LocalCursor::applyShape(const CursorShapeMessage&)
{
    return false;
}

bool LocalCursor::isActive() const
{
    return false;
}

void LocalCursor::setUseHostShape(bool)
{
}

void LocalCursor::setVideoScale(double)
{
}
