//
//  LayoutBuddyTests.swift
//  LayoutBuddyTests
//
//  Created by Mykola Melnyk on 10.08.2025.
//

import Testing
@testable import LayoutBuddy

struct LayoutBuddyTests {

    @Test func ukrainianWordConversionProducesAsciiApostrophe() throws {
        let delegate = AppDelegate()
        let result = delegate.convert("п’ять", from: "uk", to: "en")
        #expect(result == "g'znm")
        #expect(result.contains("'"))
    }

}
