#!/usr/bin/env swift
// Builds the bundled word-frequency lists (LayoutBuddy/Resources/words-*.txt)
// from hermitdave/FrequencyWords (OpenSubtitles 2018, CC BY-SA 4.0):
//
//   curl -LO https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_50k.txt
//   curl -LO https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/uk/uk_50k.txt
//   swift Tools/build-wordlists.swift <dir with *_50k.txt> LayoutBuddy/Resources
//
// Subtitle lists are noisy — the Ukrainian one carries Russian and English
// entries — so each word must use only its language's alphabet and be
// accepted by the macOS spell-checker for that language. Single letters are
// dropped: the decider has its own explicit single-letter word lists.

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: build-wordlists.swift <input dir> <output dir>\n".data(using: .utf8)!)
    exit(2)
}
let inputDir = URL(fileURLWithPath: args[1])
let outputDir = URL(fileURLWithPath: args[2])

struct Language {
    let code: String
    let alphabet: Set<Character>
}

let languages = [
    Language(code: "en", alphabet: Set("abcdefghijklmnopqrstuvwxyz")),
    Language(code: "uk", alphabet: Set("абвгґдеєжзиіїйклмнопрстуфхцчшщьюя")),
]

let checker = NSSpellChecker.shared
let tag = NSSpellChecker.uniqueSpellDocumentTag()

for language in languages {
    guard let spellLanguage = checker.availableLanguages.first(where: { $0.hasPrefix(language.code) }) else {
        FileHandle.standardError.write("no spell-checker for \(language.code)\n".data(using: .utf8)!)
        exit(1)
    }
    let input = inputDir.appendingPathComponent("\(language.code)_50k.txt")
    let text = try String(contentsOf: input, encoding: .utf8)

    var kept: [String] = []
    var dropped = 0
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ")
        guard parts.count == 2, let count = Int(parts[1]) else { dropped += 1; continue }
        let word = String(parts[0]).lowercased()
        guard word.count >= 2, word.allSatisfy(language.alphabet.contains) else { dropped += 1; continue }
        let miss = checker.checkSpelling(of: word, startingAt: 0, language: spellLanguage, wrap: false,
                                         inSpellDocumentWithTag: tag, wordCount: nil)
        guard miss.location == NSNotFound else { dropped += 1; continue }
        kept.append("\(word)\t\(count)")
    }

    let header = "# \(language.code) word frequencies — FrequencyWords (OpenSubtitles 2018), CC BY-SA 4.0,\n"
        + "# https://github.com/hermitdave/FrequencyWords — filtered by Tools/build-wordlists.swift\n"
    let output = outputDir.appendingPathComponent("words-\(language.code).txt")
    try (header + kept.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
    print("\(language.code): kept \(kept.count), dropped \(dropped) → \(output.path)")
}
