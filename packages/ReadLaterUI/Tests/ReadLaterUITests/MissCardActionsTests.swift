import Testing
@testable import ReadLaterUI
import ReadLaterCore

// The miss card shows one secondary action: the offer, the web search, or
// neither (Close only). Four cells cover online/offline x pack installed/absent.

@Test func onlineAbsentShowsOfferNotSearch() {
    let kind = MissKind.notInDictionary
    #expect(MissCard.showsOffer(kind: kind, packInstalled: false, isOnline: true, offerDeclined: false))
    #expect(!MissCard.showsSearch(kind: kind, packInstalled: false, isOnline: true, offerDeclined: false))
}

@Test func onlineInstalledShowsSearchNotOffer() {
    let kind = MissKind.notInDictionary
    #expect(!MissCard.showsOffer(kind: kind, packInstalled: true, isOnline: true, offerDeclined: false))
    #expect(MissCard.showsSearch(kind: kind, packInstalled: true, isOnline: true, offerDeclined: false))
}

/// Offline and no pack. Close only.
@Test func offlineAbsentShowsCloseOnly() {
    let kind = MissKind.notInDictionary
    #expect(!MissCard.showsOffer(kind: kind, packInstalled: false, isOnline: false, offerDeclined: false))
    #expect(!MissCard.showsSearch(kind: kind, packInstalled: false, isOnline: false, offerDeclined: false))
}

/// Offline with the pack installed. Close only.
@Test func offlineInstalledShowsCloseOnly() {
    let kind = MissKind.notInDictionary
    #expect(!MissCard.showsOffer(kind: kind, packInstalled: true, isOnline: false, offerDeclined: false))
    #expect(!MissCard.showsSearch(kind: kind, packInstalled: true, isOnline: false, offerDeclined: false))
}

@Test func onlineAbsentDeclinedShowsSearchNotOffer() {
    let kind = MissKind.notInDictionary
    #expect(!MissCard.showsOffer(kind: kind, packInstalled: false, isOnline: true, offerDeclined: true))
    #expect(MissCard.showsSearch(kind: kind, packInstalled: false, isOnline: true, offerDeclined: true))
}

@Test func noNetworkMissShowsNeitherAction() {
    for installed in [false, true] {
        #expect(!MissCard.showsOffer(kind: .noNetwork, packInstalled: installed, isOnline: true, offerDeclined: false))
        #expect(!MissCard.showsSearch(kind: .noNetwork, packInstalled: installed, isOnline: true, offerDeclined: false))
    }
}
