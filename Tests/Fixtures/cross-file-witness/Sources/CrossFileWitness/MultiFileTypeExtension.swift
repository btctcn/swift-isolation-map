// See MultiFileType.swift's own comment -- this extension, in a *different* file from
// `MultiFileType`'s own primary declaration, states a *second* conformance
// (`MultiFileSecondProtocol`) that file's own independent extraction never sees.
protocol MultiFileSecondProtocol {}
extension MultiFileType: MultiFileSecondProtocol {}
