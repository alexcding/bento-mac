import Foundation

/// Ready-made docs for study and reading, as Craft's templates: a structure to fill in.
public struct DocTemplate: Hashable, Identifiable, Sendable {
  public let name: String
  public let symbol: String
  /// The doc's blocks, as Markdown.
  public let markdown: String
  public var id: String { name }

  public var blocks: [DocContent] { DocMarkdown.blocks(from: markdown) }

  public static let all: [DocTemplate] = [lecture, reading, studyPlan, flashcards, meeting]

  public static let lecture = DocTemplate(
    name: "Lecture Notes", symbol: "graduationcap",
    markdown: """
      ## Key ideas
      -
      ## Notes

      ## Questions
      - [ ]
      ## Summary
      > In one paragraph:
      """
  )

  public static let reading = DocTemplate(
    name: "Reading Notes", symbol: "book",
    markdown: """
      ## Source
      Author, title, link
      ## Highlights
      >
      ## My thoughts

      ## To follow up
      - [ ]
      """
  )

  public static let studyPlan = DocTemplate(
    name: "Study Plan", symbol: "calendar",
    markdown: """
      ## Goal

      ## This week
      - [ ]
      ## Topics
      | Topic | Status | Next review |
      | --- | --- | --- |
      |  |  |  |
      ## Resources
      -
      """
  )

  public static let flashcards = DocTemplate(
    name: "Flashcards", symbol: "rectangle.on.rectangle.angled",
    markdown: """
      Each toggle is a card: the question on top, the answer folded inside.
      ▸ Question
        Answer
      ▸ Question
        Answer
      """
  )

  public static let meeting = DocTemplate(
    name: "Meeting Notes", symbol: "person.2",
    markdown: """
      ## Attendees
      -
      ## Agenda
      1. First topic
      ## Notes

      ## Action items
      - [ ]
      """
  )
}
