// Book hints remain in the EPUB; Anx owns their controls outside the text.
export function hideEmbeddedHintControls(doc) {
    if (!doc?.head || doc.getElementById('anx-native-hint-controls')) return
    const style = doc.createElement('style')
    style.id = 'anx-native-hint-controls'
    style.textContent = '[data-anx-edit-added="controls"],.rl-toolbar{display:none!important}'
    doc.head.appendChild(style)
    const translatePopup = () => {
        for (const popup of doc.querySelectorAll('.rl-popup')) {
            popup.setAttribute('aria-label', 'Explanation')
            const close = popup.querySelector('button')
            if (close && close.textContent !== 'Close ×') close.textContent = 'Close ×'
        }
    }
    translatePopup()
    const observer = new doc.defaultView.MutationObserver(translatePopup)
    observer.observe(doc.documentElement, { childList: true, subtree: true })
}

function windows(host) {
    const contents = host.reader?.view?.renderer?.getContents?.() ?? []
    return [...new Set([host, ...contents.map(x => x.doc?.defaultView).filter(Boolean)])]
}

export function getReaderHintControls(host = window) {
    const result = new Map()
    for (const win of windows(host)) {
        const levels = win.AnxReadingLevels?.get?.()
        if (levels) {
            for (const kind of ['words', 'notes']) result.set(`live:${kind}`, {
                id: `live:${kind}`, label: kind === 'words' ? 'Word hints' : 'Footnotes',
                level: levels[kind],
            })
        }
        for (const key of Object.keys(win).filter(key => key.startsWith('__anxEditGroups_'))) {
            const manager = win[key]
            if (typeof manager?.groups?.keys !== 'function' || !manager.levels) continue
            for (const group of manager.groups.keys()) {
                const id = JSON.stringify([key, group])
                result.set(id, { id, label: group, level: manager.levels[group] ?? 3 })
            }
        }
    }
    return [...result.values()]
}

export function setReaderHintLevel(id, level, host = window) {
    if (![0, 1, 2, 3].includes(level)) return false
    let changed = false
    for (const win of windows(host)) {
        if (id === 'live:words' || id === 'live:notes') {
            if (!win.AnxReadingLevels) continue
            win.AnxReadingLevels.set({ [id.slice(5)]: level })
            changed = true
        } else {
            let parts
            try { parts = JSON.parse(id) } catch (_) { continue }
            if (!Array.isArray(parts) || parts.length !== 2 || !parts[0].startsWith('__anxEditGroups_')) continue
            const manager = win[parts[0]], group = parts[1]
            const select = manager?.groups?.get(group)?.querySelector('select')
            if (!select) continue
            select.value = String(level)
            select.dispatchEvent(new win.Event('change'))
            changed = true
        }
    }
    return changed
}

export async function refreshReaderHints(host = window) {
    const runtimes = windows(host).map(win => win.readingLive).filter(api => typeof api?.refresh === 'function')
    await Promise.all(runtimes.map(api => api.refresh()))
    return runtimes.length
}

// Tags live in the EPUB. The reader owns the filter and never rewrites links or
// replaces ruby base text; hidden glosses must leave the original word intact.
export function normalizeHintTags(raw, maxCategories = 16, maxValues = 16) {
    if (raw == null) return {}
    if (typeof raw !== 'object' || Array.isArray(raw) || Object.keys(raw).length > maxCategories) throw new Error('Invalid hint tag categories')
    const entries = [], keys = new Set()
    for (const [name, values] of Object.entries(raw)) {
        const key = name.trim().toLowerCase()
        if (!key || key.length > 32 || /[\x00-\x1f\x7f]/.test(key) || keys.has(key) || !Array.isArray(values) || !values.length || values.length > maxValues) throw new Error('Invalid hint tags')
        keys.add(key)
        const unique = new Map()
        for (const value of values) {
            if (typeof value !== 'string' || !value.trim() || value.trim().length > 64 || /[\x00-\x1f\x7f]/.test(value)) throw new Error('Invalid hint tag value')
            if (!unique.has(value.trim().toLowerCase())) unique.set(value.trim().toLowerCase(), value.trim())
        }
        entries.push([key, [...unique.values()].sort()])
    }
    return Object.fromEntries(entries.sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0))
}

const hintSelector = '[data-anx-hint-highlight], [data-anx-pdf-hint], rt:not([data-anx-ruby-container]), [data-anx-ruby-gloss], [data-anx-ai-ref], .anx-edit-ref-wrap, .rl-ref'
function hintTags(element) {
    let tags = {}
    try {
        const source = element.getAttribute('data-anx-hint-tags') ?? element.closest('ruby')?.getAttribute('data-anx-hint-tags')
        if (source && source.length <= 65536) tags = normalizeHintTags(JSON.parse(source))
    } catch (_) { /* Untrusted/malformed book metadata is an untagged hint. */ }
    const tier = Number(element.getAttribute('data-anx-edit-tier') ?? element.getAttribute('data-tier') ?? element.closest('ruby')?.getAttribute('data-tier'))
    if (!tags.verbosity && [1, 2, 3].includes(tier)) tags.verbosity = [['Few'], ['Some'], ['Many']][tier - 1]
    const group = element.getAttribute('data-anx-edit-group')
    if (!tags.group && group) tags.group = [group]
    return tags
}
function matchesHintFilter(tags, filter) {
    const intersects = (key, values) => (Object.hasOwn(tags, key) ? tags[key] : []).some(value => values.some(wanted => wanted.toLowerCase() === value.toLowerCase()))
    return !Object.entries(filter.exclude).some(([key, values]) => intersects(key, values)) &&
        (!Object.keys(filter.only).length || Object.entries(filter.only).some(([key, values]) => intersects(key, values)))
}
function hintDocuments(host) {
    return [...new Set([host.document, ...windows(host).map(win => win.document)].filter(Boolean))]
}
function applyHintFilter(doc, host) {
    // Density is now represented by tags. Retired book controls must not keep
    // hiding hints behind the reader's tag filter, including late live hints.
    for (const control of getReaderHintControls(host)) {
        if (control.level !== 3) setReaderHintLevel(control.id, 3, host)
    }
    const filter = host.__anxHintFilter ?? { only: {}, exclude: {} }
    if (!Object.keys(filter.only).length && !Object.keys(filter.exclude).length) {
        for (const element of doc.querySelectorAll('[data-anx-hint-filtered]')) element.removeAttribute('data-anx-hint-filtered')
        return
    }
    for (const element of doc.querySelectorAll(hintSelector)) {
        const hidden = !matchesHintFilter(hintTags(element), filter)
        if (hidden) {
            if (element.getAttribute('data-anx-hint-filtered') !== '1') element.setAttribute('data-anx-hint-filtered', '1')
        } else if (element.hasAttribute('data-anx-hint-filtered')) element.removeAttribute('data-anx-hint-filtered')
    }
}
export function installReaderHintFilters(doc, host = window) {
    if (!doc?.head) return
    if (!doc.getElementById('anx-native-hint-filter')) {
        const style = doc.createElement('style')
        style.id = 'anx-native-hint-filter'
        // ID specificity keeps a book's "show level" selectors from undoing Hide.
        style.textContent = ':is(#__anx_hint_filter_specificity__,[data-anx-hint-filtered="1"]):not([data-anx-hint-highlight]){display:none!important}[data-anx-hint-highlight][data-anx-hint-filtered="1"]{background:transparent!important}'
        doc.head.appendChild(style)
    }
    if (!doc.__anxHintFilterObserver) {
        let queued = false
        const observer = new doc.defaultView.MutationObserver(() => {
            if (queued) return
            queued = true
            queueMicrotask(() => { queued = false; applyHintFilter(doc, host) })
        })
        observer.observe(doc.documentElement, { childList: true, subtree: true, attributes: true,
            attributeFilter: ['data-anx-hint-tags', 'data-tier', 'data-anx-edit-tier', 'data-anx-edit-group'] })
        doc.__anxHintFilterObserver = observer
    }
    applyHintFilter(doc, host)
}
export function setReaderHintFilter(raw, host = window) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('Invalid hint filter')
    host.__anxHintFilter = { only: normalizeHintTags(raw.only, 128, 512), exclude: normalizeHintTags(raw.exclude, 128, 512) }
    for (const doc of hintDocuments(host)) installReaderHintFilters(doc, host)
    return true
}
export function getReaderHintTags(host = window) {
    const facets = new Map()
    for (const doc of hintDocuments(host)) {
        for (const element of doc.querySelectorAll(hintSelector)) {
            for (const [key, values] of Object.entries(hintTags(element))) {
                if (!facets.has(key)) facets.set(key, new Map())
                for (const value of values) facets.get(key).set(value.toLowerCase(), value)
            }
        }
    }
    return Object.fromEntries([...facets].map(([key, values]) => [key, [...values.values()].sort()]))
}

const paint = host => new Promise(resolve => host.requestAnimationFrame(() => host.requestAnimationFrame(resolve)))

// Temporarily render a real sample from the loaded chapter for a native
// screenshot. No book data, saved filter, navigation history or progress changes.
export async function beginReaderHintPreview(raw, host = window) {
    if (host.__anxHintPreview) throw new Error('A hint preview is already open')
    const view = host.reader?.view
    const contents = view?.renderer?.getContents?.() ?? []
    const location = view?.lastLocation?.range
    const content = contents.find(x => x.doc === location?.startContainer.ownerDocument) ??
        contents.find(x => x.index === view?.renderer?.index)
    if (!content?.doc || !location && !view.book?.isPDF) throw new Error('The chapter is not ready for preview')
    const filter = { only: normalizeHintTags(raw.only, 128, 512), exclude: normalizeHintTags(raw.exclude, 128, 512) }
    const matches = [...content.doc.querySelectorAll(hintSelector)].filter(el => matchesHintFilter(hintTags(el), filter))
    const caret = location?.cloneRange(); caret?.collapse(true)
    host.__anxHintPreview = { filter: host.__anxHintFilter ?? {}, index: content.index, caret }
    try {
        setReaderHintFilter(filter, host)
        const target = matches.find(el => { try { return location?.intersectsNode(el) } catch (_) { return false } }) ?? matches[0]
        if (target && !view.book?.isPDF) {
            const range = content.doc.createRange()
            range.selectNodeContents(target.closest('ruby') ?? target); range.collapse(true)
            await view.renderer.goTo({ index: content.index, anchor: () => range })
        }
        await paint(host)
        return { matches: matches.length }
    } catch (error) {
        await endReaderHintPreview(host)
        throw error
    }
}

export async function endReaderHintPreview(host = window) {
    const preview = host.__anxHintPreview
    if (!preview) return false
    try {
        setReaderHintFilter(preview.filter, host)
        if (!host.reader?.view?.book?.isPDF) {
            await host.reader.view.renderer.goTo({ index: preview.index, anchor: () => preview.caret })
        }
        await paint(host)
        return true
    } finally {
        delete host.__anxHintPreview
    }
}
