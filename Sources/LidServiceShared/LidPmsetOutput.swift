import Foundation

public enum LidPmsetOutput {
    public static func sleepDisabled(_ output: String) -> Bool? {
        guard output.contains("System-wide power settings:") else { return nil }
        for line in output.split(separator: "\n") {
            let columns = line.split(whereSeparator: \.isWhitespace)
            if columns.count >= 2 && columns[0] == "SleepDisabled" {
                switch columns[1] {
                case "0": return false
                case "1": return true
                default: return nil
                }
            }
        }
        // A fresh system commonly omits this system-wide override altogether.
        return false
    }
}
