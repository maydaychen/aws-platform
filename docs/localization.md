# Localization

The interface supports English and Simplified Chinese. `LanguageSettings` stores only the application language preference; the app injects its resolved locale into the window and native Settings scenes. Language changes must not change view identity, select a Profile, reload data, or invalidate resource state.

## Display boundary

- Keep API values, identifiers, enum raw values, filter tags, persistence keys, Profile names, resource names, AWS tags, log bodies, and event descriptions unchanged.
- Views read `@Environment(\.locale)` and use `L10n.text(key, locale: locale)` for app-owned labels. Use `L10n.format(key, arguments..., locale: locale)` for new interpolated text. Parameters are substituted verbatim, including percent signs and Unicode.
- Shared empty states, notices, section titles, tab labels, and search fields translate their display strings. `DetailGrid` translates labels only; pass `localizesLabels: false` for AWS dimension names. `DetailKeyValueRows` preserves both keys and values. Service field components have equivalent flags for external labels and explicit error messages.
- Stored app messages remain in English so already-loaded errors can be rendered again after a language change without issuing requests. The renderer recognizes catalog templates with `%@` placeholders. Ambiguous legacy parameter delimiters fall back to the original text. Prefer explicit `L10n.format` parameters or structured resource failures over adding broad templates for raw data.
- `Resources/MessageArguments.json` lists zero-based parameter indexes that are themselves app error messages. Only these parameters are resolved recursively. Never mark resource or Profile names as nested messages.

## Resources

Maintain the same keys in `Resources/en.lproj/Localizable.strings` and `Resources/zh-Hans.lproj/Localizable.strings`. English keys are the English values. Chinese format values use positional placeholders such as `%1$@` and `%2$@`. Preserve parameter counts and use Chinese punctuation with spaces between Chinese and Latin text or numbers.

The Swift package declares `defaultLocalization: "en"` and processes `Resources`. The resolver explicitly selects the requested language inside `Bundle.module`, including when it differs from the host system language. The Universal packaging script copies the module bundle, checks both language files and message metadata for each architecture, and declares both languages in the application Info.plist.

## Verification

Run `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`. `LocalizationTests` checks preference persistence, language resolution, catalog parity, parameter preservation, existing error rendering, and fallback behavior. For UI changes, inspect English and Chinese rendering at the minimum supported window width and with long names/messages. Changing only the locale must preserve mounted state and must not trigger AWS requests.
