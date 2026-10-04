import SwiftUI

/// Uses a native menu when all section titles cannot fit in the detail pane.
struct DetailTabPicker<Tab: Hashable & Identifiable & RawRepresentable>: View where Tab.RawValue == String {
    @Environment(\.locale) private var locale
    let tabs: [Tab]
    @Binding var selection: Tab

    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker.pickerStyle(.segmented).labelsHidden().fixedSize(horizontal: true, vertical: false)
            picker.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var picker: some View {
        Picker(L10n.text("Section", locale: locale), selection: $selection) {
            ForEach(tabs) { tab in Text(L10n.text(tab.rawValue, locale: locale)).tag(tab) }
        }
    }
}
