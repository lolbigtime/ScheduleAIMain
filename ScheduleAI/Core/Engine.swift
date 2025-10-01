//
//  Engine.swift
//  ScheduleAI
//
//  Created by Tai Wong on 10/1/25.
//

import Foundation
import Folio
import Combine

public class Engine: ObservableObject {
    public let folio: FolioEngine
    
    
    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folioDir = appSupport.appendingPathComponent("Folio", isDirectory: true)
        
        try? FileManager.default.createDirectory(at: folioDir, withIntermediateDirectories: true)
        let dbURL = folioDir.appendingPathComponent("folio.sqlite")
        
        
        let pdfLoader = PDFDocumentLoader()
        let textLoader = TextDocumentLoader()

        let chunker = UniversalChunker()
        
        self.folio = try! FolioEngine(databaseURL: dbURL, loaders: [pdfLoader, textLoader], chunker: chunker, embedder: nil)
        
    }
}
