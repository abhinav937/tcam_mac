//
//  Item.swift
//  tcam_mac
//
//  Created by Abhinav Chinnusamy on 4/13/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
