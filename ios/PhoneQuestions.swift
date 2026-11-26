import SwiftUI

/// The question Claude is waiting on, drawn on the controller itself. Several questions come one at a time and
/// multi-select questions get a confirm button, like the cards on the Mac stage.
@MainActor
struct PhoneQuestionCard: View {
  let card: PhoneWhipWire.QuestionCard
  let dismiss: () -> Void
  let issue: String?
  let pal: Palette
  /// What was dictated with the main mic: it becomes the answer to the question on show.
  @Binding var dictated: String?
  let send: (_ decision: String, _ answers: [String: String]?) -> Void

  @State private var index = 0
  @State private var answers: [String: String] = [:]
  @State private var picked: Set<String> = []

  private var question: PhoneWhipWire.QuestionCard.Question { card.questions[index] }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(card.title.isEmpty ? card.folder : "\(card.folder) · \(card.title)")
          .font(.footnote).foregroundStyle(pal.subtext).lineLimit(1)
        Spacer()
        Button(action: dismiss) {
          Image(systemName: "chevron.down").font(.system(size: 18, weight: .bold)).foregroundStyle(pal.subtext)
            .frame(width: 44, height: 32)
        }
        .buttonStyle(.plain)
      }
      if let header = question.header { Text(header).font(.caption.weight(.bold)).foregroundStyle(pal.peach) }
      Text(question.question).font(.headline).foregroundStyle(pal.text)
      ScrollView {
        VStack(spacing: 10) {
          ForEach(question.options, id: \.label) { option in
            let on = picked.contains(option.label)
            Button { tap(option.label) } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(option.label).font(.body.weight(.semibold))
                if let detail = option.description, !detail.isEmpty {
                  Text(detail).font(.footnote).opacity(0.75).multilineTextAlignment(.leading)
                }
              }
              .foregroundStyle(on ? pal.onAccent : pal.text)
              .padding(16)
              .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
              .background(on ? pal.peach : pal.surface0, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
          }
        }
      }
      if let issue { Text(issue).font(.footnote).foregroundStyle(pal.red) }
      HStack(spacing: 12) {
        Button { send("deny", nil) } label: {
          Image(systemName: "xmark").font(.system(size: 22, weight: .bold))
            .foregroundStyle(pal.red).frame(maxWidth: .infinity, minHeight: 56)
            .background(pal.red.opacity(0.16), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        if question.multiSelect {
          Button { finish(question.options.map(\.label).filter(picked.contains).joined(separator: ", ")) } label: {
            Image(systemName: "checkmark").font(.system(size: 22, weight: .bold))
              .foregroundStyle(pal.onAccent).frame(maxWidth: .infinity, minHeight: 56)
              .background(pal.green.opacity(picked.isEmpty ? 0.35 : 1), in: RoundedRectangle(cornerRadius: 18))
          }
          .buttonStyle(.plain).disabled(picked.isEmpty)
        }
      }
    }
    .onChange(of: dictated, initial: true) { _, text in
      guard let text, !text.isEmpty else { return }
      dictated = nil
      finish(text)
    }
    .padding(16)
    .background(pal.mantle, in: RoundedRectangle(cornerRadius: 26))
    .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(pal.peach.opacity(0.5), lineWidth: 1.5))
  }

  private func tap(_ label: String) {
    guard question.multiSelect else { finish(label); return }
    if !picked.insert(label).inserted { picked.remove(label) }
  }

  private func finish(_ value: String) {
    answers[question.question] = value
    if index + 1 < card.questions.count {
      index += 1
      picked = []
    } else {
      send("allow", answers)
    }
  }
}
