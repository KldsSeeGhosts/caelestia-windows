// The Windows capture source has no dimensions until its first frame. Reserve
// the viewport before the original popout starts its upstream animation.
ActiveWindowContent {
    reservePreviewGeometry: true
}
