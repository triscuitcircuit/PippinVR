import Foundation
@main struct Test {
    static func main() {
        var decoder = DirectHostRequests()
        assert(decoder.receive(Data("log line\nPIPPINVR_RE".utf8)).isEmpty)
        assert(decoder.receive(Data("QUEST:1\nPIPPINVR_REQUEST:2\n".utf8)) == [1, 2])
        assert(decoder.receive(Data("PIPPINVR_REQUEST:9\nPIPPINVR_REQUEST:01\n".utf8)).isEmpty)
        assert(decoder.receive(Data((String(repeating: "a", count: 5000) + "PIPPINVR_REQUEST:1\n").utf8)).isEmpty)
        assert(decoder.receive(Data("PIPPINVR_REQUEST:1\n".utf8)) == [1])
        assert(decoder.receive(Data("PIPPINVR_REQUEST:3\nPIPPINVR_REQUEST:4\n".utf8)) == [3, 4])
        assert(decoder.receive(Data("NEWT_RE".utf8)).isEmpty)
        assert(decoder.receive(Data("QUEST:1\nNEWT_REQUEST:3\nNEWT_REQUEST:4\n".utf8)) == [1, 3, 4])
        assert(decoder.receive(Data("NEWT_REQUEST:01\nNEWT_REQUEST:100\n".utf8)) == [100])
        assert(decoder.receive(Data("NEWT_REQUEST:100\n".utf8)) == [100])
        assert(decoder.receive(Data("PIPPINVR_REQUEST:105\n".utf8)) == [105])
        print("PASS: fragmented and batched requests, unknown messages, oversized lines, recovery, indexed app-pick codes")
    }
}
