#if canImport(SwiftUI)
import SwiftUI

public struct ProviderModelMenuModel: Identifiable, Hashable {
    public var id: String
    public var modelID: String
    public var variantID: String?
    public var title: String
    public var detail: String?

    public init(id: String, title: String, detail: String? = nil) {
        self.id = id
        self.modelID = id
        self.variantID = nil
        self.title = title
        self.detail = detail
    }

    public init(id: String,
                modelID: String,
                variantID: String?,
                title: String,
                detail: String? = nil) {
        self.id = id
        self.modelID = modelID
        self.variantID = variantID
        self.title = title
        self.detail = detail
    }
}

public struct ProviderModelMenuProvider: Identifiable, Hashable {
    public var id: String
    public var title: String
    public var models: [ProviderModelMenuModel]

    public init(id: String, title: String, models: [ProviderModelMenuModel]) {
        self.id = id
        self.title = title
        self.models = models
    }
}

public struct ProviderModelSelectionMenu<LabelContent: View>: View {
    private let providers: [ProviderModelMenuProvider]
    private let selectedProviderID: String
    private let selectedModelID: String
    private let selectedVariantID: String?
    private let isBusy: Bool
    private let onSelect: (String, String, String?) -> Void
    private let label: () -> LabelContent

    public init(providers: [ProviderModelMenuProvider],
                selectedProviderID: String,
                selectedModelID: String,
                selectedVariantID: String?,
                isBusy: Bool,
                onSelect: @escaping (String, String, String?) -> Void,
                @ViewBuilder label: @escaping () -> LabelContent) {
        self.providers = providers
        self.selectedProviderID = selectedProviderID
        self.selectedModelID = selectedModelID
        self.selectedVariantID = selectedVariantID
        self.isBusy = isBusy
        self.onSelect = onSelect
        self.label = label
    }

    public init(providers: [ProviderModelMenuProvider],
                selectedProviderID: String,
                selectedModelID: String,
                isBusy: Bool,
                onSelect: @escaping (String, String) -> Void,
                @ViewBuilder label: @escaping () -> LabelContent) {
        self.init(
            providers: providers,
            selectedProviderID: selectedProviderID,
            selectedModelID: selectedModelID,
            selectedVariantID: nil,
            isBusy: isBusy,
            onSelect: { providerID, modelID, _ in
                onSelect(providerID, modelID)
            },
            label: label)
    }

    public var body: some View {
        Menu {
            ForEach(providers) { provider in
                Section(provider.title) {
                    ForEach(provider.models) { model in
                        Button {
                            onSelect(provider.id, model.modelID, model.variantID)
                        } label: {
                            Label {
                                HStack(spacing: 5) {
                                    Text(model.title)
                                    if let detail = model.detail, !detail.isEmpty {
                                        Text(detail)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: isSelected(
                                    providerID: provider.id,
                                    modelID: model.modelID,
                                    variantID: model.variantID) ? "checkmark" : "circle")
                            }
                        }
                    }
                }
            }
        } label: {
            label()
        }
        .disabled(isBusy)
    }

    private func isSelected(providerID: String,
                            modelID: String,
                            variantID: String?) -> Bool {
        selectedProviderID == providerID
            && selectedModelID == modelID
            && selectedVariantID == variantID
    }
}
#endif
