// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Glendon Chin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// A copy is included in /LICENSE in the repository root.

import SwiftUI

/// Environment seam for content rendered inside a nook to reach the
/// surface controller hosting it.
///
/// Compact-row buttons (e.g. a routing quick-action) can request
/// expansion without the host threading the `Nook` instance through
/// every view or widening public registration APIs.
private struct NookSurfaceControlKey: EnvironmentKey {
    static let defaultValue: NookControllable? = nil
}

public extension EnvironmentValues {
    /// The `NookControllable` hosting the current content, or `nil` when
    /// the view is not inside a nook surface.
    var nookSurface: NookControllable? {
        get { self[NookSurfaceControlKey.self] }
        set { self[NookSurfaceControlKey.self] = newValue }
    }
}
