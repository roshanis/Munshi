import Foundation

/// A tiny DOM built on `XMLParser`, used for the XML files inside EPUBs (container, OPF, NCX, nav).
///
/// Element and attribute names are stored without their namespace prefix, so `dc:title` becomes
/// `title` and `epub:type` becomes `type`.
final class MiniXMLElement {
    let name: String
    let attributes: [String: String]
    private(set) var children: [MiniXMLElement] = []
    fileprivate(set) var text = ""
    weak var parent: MiniXMLElement?

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    subscript(attribute: String) -> String? { attributes[attribute] }

    /// The concatenated text of this element and all its descendants, whitespace-collapsed.
    var allText: String {
        var pieces = [text]
        for child in children { pieces.append(child.allText) }
        return pieces.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    func child(_ name: String) -> MiniXMLElement? {
        children.first { $0.name == name }
    }

    func children(_ name: String) -> [MiniXMLElement] {
        children.filter { $0.name == name }
    }

    /// Depth-first search over all descendants.
    func descendants(_ name: String) -> [MiniXMLElement] {
        var result: [MiniXMLElement] = []
        for child in children {
            if child.name == name { result.append(child) }
            result.append(contentsOf: child.descendants(name))
        }
        return result
    }

    func firstDescendant(_ name: String) -> MiniXMLElement? {
        for child in children {
            if child.name == name { return child }
            if let found = child.firstDescendant(name) { return found }
        }
        return nil
    }

    fileprivate func append(_ child: MiniXMLElement) {
        child.parent = self
        children.append(child)
    }

    static func parse(_ data: Data) throws -> MiniXMLElement {
        let builder = Builder()
        let parser = XMLParser(data: Self.replacingHTMLEntities(in: data))
        parser.delegate = builder
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        return root
    }

    /// XHTML files often use HTML named entities that `XMLParser` does not know about.
    private static func replacingHTMLEntities(in data: Data) -> Data {
        guard var string = String(data: data, encoding: .utf8), string.contains("&") else { return data }
        let entities = [
            "&nbsp;": "&#160;", "&mdash;": "&#8212;", "&ndash;": "&#8211;",
            "&hellip;": "&#8230;", "&lsquo;": "&#8216;", "&rsquo;": "&#8217;",
            "&ldquo;": "&#8220;", "&rdquo;": "&#8221;", "&copy;": "&#169;",
        ]
        for (entity, numeric) in entities {
            string = string.replacingOccurrences(of: entity, with: numeric)
        }
        return Data(string.utf8)
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: MiniXMLElement?
        private var stack: [MiniXMLElement] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            var localAttributes: [String: String] = [:]
            for (key, value) in attributes {
                localAttributes[Self.localName(key)] = value
            }
            let element = MiniXMLElement(name: Self.localName(elementName), attributes: localAttributes)
            if let parent = stack.last {
                parent.append(element)
            } else {
                root = element
            }
            stack.append(element)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.text += String(data: CDATABlock, encoding: .utf8) ?? ""
        }

        private static func localName(_ name: String) -> String {
            guard let colon = name.lastIndex(of: ":") else { return name }
            return String(name[name.index(after: colon)...])
        }
    }
}
