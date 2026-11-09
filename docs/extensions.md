# Reader extensions (API version 1, Android preview)

Extensions add AI tools without adding service-specific code to the reader. The first consumer is the separately maintained [NotebookLM extension](https://github.com/folex/anx-notebooklm-extension). No Anx server is required.

## Package and entry point

Install a `.anxplugin` ZIP from Settings → AI → Extensions. Its compressed and expanded sizes must fit within 1 MB. Only `manifest.json`, `plugin.js`, `README.md` and `LICENSE` entries are accepted. The manifest declares `apiVersion: 1`, a stable lowercase `id`, version, permissions, exact HTTPS origins, optional `authUrl` / authentication-only `authOrigins`, and tools with JSON parameter schemas. The NotebookLM manifest is a complete example.

```js
module.exports.invoke = async (toolName, arguments, api) => {
  const book = await api.call('reader.context');
  return { title: book.title };
};
```

A fresh headless Android WebView executes each tool call. It is separate from book content. Direct WebView networking and filesystem access are disabled. Host calls are asynchronous JSON messages. A call expires after three minutes, and its result is limited to 100 KB. This is a restricted capability host for trusted extensions, not a security certification for arbitrary JavaScript or a CPU-budgeted sandbox.

## Capabilities

| Permission | Host APIs |
|---|---|
| `books.read` | `reader.context`, `reader.currentChapter`, `reader.bookText`, `reader.listBooks` |
| `books.write` | `reader.edit` for the existing footnote, ruby and highlight tools |
| `network` | `network.request`, `files.download`, restricted to declared origins |
| `ui` | The host-provided sign-in screen |

`storage.get`, `storage.set` and `storage.claim` provide namespaced JSON storage; individual values are limited to 128 KB. `claim` atomically returns an existing value or creates it and returns null. Use it for operation receipts before externally visible mutations.

Every host call checks the manifest and current grants. Permission changes invalidate active invocations; an HTTP request already accepted by the transport may still finish. Extensions cannot grant themselves more permissions. Reinstalling a package requires permission review.

### Reader arguments

- `reader.context {}` returns the open book ID/title and chapter title/href.
- `reader.currentChapter {bookId?}` returns original current EPUB chapter text or the text-based PDF bridge's current page/chapter. A supplied ID must match the open book. Chapter changes cancel the request.
- `reader.bookText {bookId?}` returns the EPUB spine as `{href, sourceHref, title, text}` chapters. The ID can select a library book that is not open. Whole-PDF export and OCR are not implemented.
- `reader.listBooks {}` returns available IDs, titles and authors.
- `reader.edit {name, arguments}` delegates to `add_book_footnote`, `add_book_ruby` or `add_book_highlight`, retaining their anchor checks and batch behavior.

Whole EPUB export is capped at 100 MB archive size, 8 MB per entry and 4 MB extracted text. Generated hint text is excluded. Full library export can include unread content and must be requested explicitly.

### Transport and artifacts

`network.request {url, method?, body?, sessionScope?}` accepts GET or POST and returns status, response text, final URL and a session fingerprint. Native HTTP validates exact HTTPS origins on every hop. POST redirects are rejected rather than replayed. Cookies are attached natively for the destination and never returned to plugin code. The plugin can read the response page, including its CSRF fields; install only extensions whose authors are trusted.

`files.download {url, filename?}` saves audio directly to an extension-specific app directory, up to 150 MB. It returns a file handle/name/size, not a filesystem path. The settings screen lists artifacts and uses Android FileProvider to open them with an audio player.

The sign-in Activity has no reader bridge. `authOrigins` permits navigation to identity-provider pages without permitting plugin network calls to them. Embedded Google sign-in and actual native runtime execution remain device-verification tasks for the first preview.

## Source and releases

The public fork preserves the upstream `develop` history. The `personal` branch starts with a documented Personal.22 import, and extension work is reviewed separately. Build artifacts and credentials stay out of source control. Personal APKs use the existing private signing key; public builds need their own signer or the published personal APK.
