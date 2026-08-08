import SwiftUI

/// The one way a layer recedes when something opens on top of it. Every surface uses this rather
/// than its own blur/opacity pair — see LayerConfig for the depths and the numbers.
extension View {
    /// Push this layer back because a deeper one is open.
    ///
    /// The wash never takes hits: it is a visual cue, and the layer underneath still owns its own
    /// dismissal (a click on empty space closes the top layer first). Whatever is drawn *above* this
    /// modifier is unaffected, which is the point — the panel doing the covering must stay crisp.
    ///
    /// `blurred: false` recedes with the wash alone. That is for the one case where this layer is
    /// still a *target*: a card being dragged can be dropped on another card, and you cannot aim at
    /// something blurred. Dimming still says "this is behind"; blurring would say "you are done
    /// reading this", which is the opposite of what a drop target needs.
    func receded(_ on: Bool, blurred: Bool = true) -> some View {
        let cfg = LayerConfig.current
        return self
            .blur(radius: on && blurred ? cfg.blur : 0)
            .overlay(Color.black.opacity(on ? cfg.dim : 0).allowsHitTesting(false))
            .animation(.easeOut(duration: cfg.duration), value: on)
            .animation(.easeOut(duration: cfg.duration), value: blurred)
    }

}

// A level-1 panel recedes only where its level-2 card actually covers it. Search does — the preview
// sits over the whole panel — so SearchPanel calls `receded`. The session tree does not: its detail
// card floats to the LEFT of the tree specifically so the tree stays visible, because the point of
// the card is to be read against the row it belongs to. Blurring it there would be damage, not
// depth. Dismissal order is the same in both cases regardless: level 2, then level 1.
