import SwiftUI

/// Every place a column can show: a screen with the view model behind it, or a placeholder.
/// Coordinators decide which destination each column holds; `view()` is the one place views are
/// built from them.
enum Destination: Hashable {
  case feed(FeedViewModel)
  case docList(DocListViewModel)
  case itemDetail(ItemDetailViewModel)
  case docPage(DocPageViewModel)
  /// Nothing chosen yet: a hint with its symbol.
  case placeholder(String, symbol: String)
}

@MainActor
extension Destination {
  /// The destination's view. Each screen takes its model's identity, so a newly chosen item or doc
  /// starts from fresh view state instead of inheriting the last one's.
  @ViewBuilder
  func view() -> some View {
    switch self {
    case .feed(let model): FeedView(model: model).id(ObjectIdentifier(model))
    case .docList(let model): DocListView(model: model).id(ObjectIdentifier(model))
    case .itemDetail(let model): ItemDetailView(model: model).id(ObjectIdentifier(model))
    case .docPage(let model): DocPageView(model: model).id(ObjectIdentifier(model))
    case .placeholder(let title, let symbol): ContentUnavailableView(title, systemImage: symbol)
    }
  }
}

// Destinations compare their view models by identity, never by state.
extension FeedViewModel: HashableObject {}
extension DocListViewModel: HashableObject {}
extension ItemDetailViewModel: HashableObject {}
extension DocPageViewModel: HashableObject {}
