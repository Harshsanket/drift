import Foundation
import Testing
@testable import Drift

@Suite("WebAPI form encoding")
struct WebAPIEncodingTests {
    @Test("plus signs are encoded so qB does not decode them as spaces")
    func plusEncoding() {
        #expect(WebAPIEngine.form([("tags", "C++")]) == "tags=C%2B%2B")
    }

    @Test("spaces and reserved characters are percent encoded")
    func reservedCharacters() {
        #expect(
            WebAPIEngine.form([("savepath", "/tmp/a b&c=d#e%f")])
                == "savepath=%2Ftmp%2Fa%20b%26c%3Dd%23e%25f"
        )
    }

    @Test("unicode is percent encoded as UTF-8")
    func unicode() {
        #expect(WebAPIEngine.form([("category", "电影")]) == "category=%E7%94%B5%E5%BD%B1")
    }

    @Test("multiple pairs are joined with ampersands")
    func multiplePairs() {
        #expect(WebAPIEngine.form([("a", "1+1"), ("b", "2 2")]) == "a=1%2B1&b=2%202")
    }
}
