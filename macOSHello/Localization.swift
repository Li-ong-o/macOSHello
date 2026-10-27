import Foundation

func L(_ key: String) -> String {
    NSLocalizedString(key, comment: key)
}

func LF(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}
