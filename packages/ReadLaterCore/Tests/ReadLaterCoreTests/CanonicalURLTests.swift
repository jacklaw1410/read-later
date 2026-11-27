import Foundation
import Testing
import ReadLaterCore

@Test func sourceParamStrippedToSameEntry() {
    #expect(CanonicalURL.canonicalize("https://article.com/introduction?source=reddit")
        == "https://article.com/introduction")
    #expect(CanonicalURL.canonicalize("https://article.com/introduction?source=reddit")
        == CanonicalURL.canonicalize("https://article.com/introduction"))
}

@Test func utmParamsStripped() {
    #expect(CanonicalURL.canonicalize("https://example.com/a?utm_source=x&utm_medium=y&utm_campaign=z")
        == "https://example.com/a")
}

@Test func knownTrackersStripped() {
    #expect(CanonicalURL.canonicalize("https://example.com/a?fbclid=1") == "https://example.com/a")
    #expect(CanonicalURL.canonicalize("https://example.com/a?gclid=1") == "https://example.com/a")
    #expect(CanonicalURL.canonicalize("https://example.com/a?igshid=1") == "https://example.com/a")
    #expect(CanonicalURL.canonicalize("https://example.com/a?ref=1") == "https://example.com/a")
}

@Test func nonTrackingQueryPreservedAndSorted() {
    #expect(CanonicalURL.canonicalize("https://example.com/a?z=1&b=2") == "https://example.com/a?b=2&z=1")
    #expect(CanonicalURL.canonicalize("https://example.com/a?page=2&utm_source=x") == "https://example.com/a?page=2")
}

@Test func percentEncodingSurvivesCanonicalization() {
    // `%2B` decodes to `+` but must not be rewritten as one: a server
    // that reads `+` as a space would fetch a different resource.
    #expect(CanonicalURL.canonicalize("https://example.com/a?q=a%2Bb") == "https://example.com/a?q=a%2Bb")
    #expect(CanonicalURL.canonicalize("https://example.com/a?q=a%2Bb&r=x") == "https://example.com/a?q=a%2Bb&r=x")
    // Hex case alone never splits an entry; unreserved escapes decode.
    #expect(CanonicalURL.canonicalize("https://example.com/a?q=a%2bb")
        == CanonicalURL.canonicalize("https://example.com/a?q=a%2Bb"))
    #expect(CanonicalURL.canonicalize("https://example.com/a?q=%7Ehome") == "https://example.com/a?q=~home")
    // Encoded separators stay data: no split, no tracker false-positive.
    #expect(CanonicalURL.canonicalize("https://example.com/a?q=a%26b") == "https://example.com/a?q=a%26b")
    #expect(CanonicalURL.canonicalize("https://example.com/a?%75tm_source=x&q=1") == "https://example.com/a?q=1")
}

@Test func fragmentDropped() {
    #expect(CanonicalURL.canonicalize("https://example.com/a#section") == "https://example.com/a")
    #expect(CanonicalURL.canonicalize("https://example.com/a?page=2#section") == "https://example.com/a?page=2")
}

@Test func defaultPortsDropped() {
    #expect(CanonicalURL.canonicalize("https://example.com:443/a") == "https://example.com/a")
    #expect(CanonicalURL.canonicalize("http://example.com:80/a") == "http://example.com/a")
    #expect(CanonicalURL.canonicalize("https://example.com:8443/a") == "https://example.com:8443/a")
}

@Test func hostLowercased() {
    #expect(CanonicalURL.canonicalize("https://EXAMPLE.COM/Path") == "https://example.com/Path")
}

@Test func invalidURLReturnsInputUnchanged() {
    #expect(CanonicalURL.canonicalize("not a url %%") == "not a url %%")
}

@Test func trailingAmpersandMergesWithSameEntry() {
    #expect(CanonicalURL.canonicalize("https://example.com/a?b=1&")
        == CanonicalURL.canonicalize("https://example.com/a?b=1"))
    #expect(CanonicalURL.canonicalize("https://example.com/a?b=1&") == "https://example.com/a?b=1")
}

@Test func emptyNameWithValueIsNotTrackingNoise() {
    #expect(CanonicalURL.canonicalize("https://example.com/a?=x") == "https://example.com/a?=x")
}
