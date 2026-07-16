import SwiftUI

struct ModelAggregatorView: View {
    @ObservedObject var viewModel: ModelDownloadViewModel

    var body: some View {
        ModelDownloadView(viewModel: viewModel)
    }
}
