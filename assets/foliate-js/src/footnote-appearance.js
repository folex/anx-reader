const defaults = Object.freeze({ fontSize: 16, backgroundOpacity: 1, blur: 0 })
const number = (value, fallback, min, max) => typeof value === 'number' && Number.isFinite(value)
    ? Math.min(max, Math.max(min, value)) : fallback
const color = (value, fallback) => typeof value === 'string' && /^#[\da-f]{6}(?:[\da-f]{2})?$/i.test(value)
    ? value.slice(0, 7).toUpperCase() : fallback
const rgba = (hex, opacity) => `rgba(${parseInt(hex.slice(1, 3), 16)}, ${parseInt(hex.slice(3, 5), 16)}, ${parseInt(hex.slice(5, 7), 16)}, ${opacity})`

export class FootnoteAppearanceController {
    #settings = { ...defaults }
    #originals = new WeakMap()
    #view = null
    #observer
    #fitDoc = null
    #fitObserver = null
    #fitFrame = null
    constructor(dialog, getTheme, host = window) {
        this.dialog = dialog
        this.getTheme = getTheme
        this.host = host
        host.getFootnoteAppearance = () => this.snapshot()
        // Compatibility for already-imported learning EPUBs, whose popups are
        // deliberately inserted into the parent reader document.
        this.#observer = new MutationObserver(records => {
            if (records.some(record => record.addedNodes.length)) this.#applyKnownPopups()
        })
        this.#observer.observe(dialog.ownerDocument.body, { childList: true, subtree: true })
    }
    snapshot() {
        const theme = this.getTheme() ?? {}
        return { ...this.#settings, foregroundColor: color(theme.fontColor, '#222222'),
            backgroundColor: color(theme.backgroundColor, '#FFFFFF') }
    }
    update(settings = {}) {
        if (!settings || typeof settings !== 'object') settings = {}
        this.#settings = {
            fontSize: number(settings.fontSize, defaults.fontSize, 12, 28),
            backgroundOpacity: number(settings.backgroundOpacity, defaults.backgroundOpacity, .2, 1),
            blur: number(settings.blur, defaults.blur, 0, 16),
        }
        this.refresh()
    }
    refresh() {
        this.#applySurface(this.dialog)
        const contents = this.#view?.renderer?.getContents?.() ?? []
        for (const { doc } of contents) this.applyDocument(doc)
        this.#applyKnownPopups()
        this.host.dispatchEvent(new CustomEvent('footnote-appearance-changed', { detail: this.snapshot() }))
    }
    attachView(view) { this.#view = view; this.refresh() }
    #fitDocument(doc) {
        if (this.#fitDoc !== doc) {
            this.#fitObserver?.disconnect()
            if (this.#fitFrame !== null) this.host.cancelAnimationFrame(this.#fitFrame)
            this.#fitFrame = null
            this.#fitDoc = doc
            this.#fitObserver = new ResizeObserver(() => this.#scheduleFit(doc))
            this.#fitObserver.observe(doc.body)
            doc.fonts?.ready.then(() => this.#scheduleFit(doc)).catch(() => {})
            for (const image of doc.images) image.addEventListener('load', () => this.#scheduleFit(doc), { once: true })
        }
        this.#scheduleFit(doc)
    }
    #scheduleFit(doc) {
        if (doc !== this.#fitDoc || this.#fitFrame !== null) return
        this.#fitFrame = this.host.requestAnimationFrame(() => {
            this.#fitFrame = null
            if (doc !== this.#fitDoc || !doc.body?.isConnected) return
            // scrollHeight is at least the iframe viewport, even for one line.
            // A content range measures the actual note without that empty area.
            const range = doc.createRange()
            range.selectNodeContents(doc.body)
            const bounds = range.getBoundingClientRect()
            const body = doc.defaultView.getComputedStyle(doc.body)
            const root = doc.defaultView.getComputedStyle(doc.documentElement)
            const px = (style, key) => parseFloat(style[key]) || 0
            // A paragraph's collapsed margins sit outside body.getBoundingClientRect.
            // Preserve the leading offset and the trailing collapsed margin too.
            let tail = Math.max(0, px(body, 'marginBottom'))
            const lastContent = parent => {
                let child = parent.lastElementChild
                while (child && (['SCRIPT', 'STYLE'].includes(child.tagName) ||
                    doc.defaultView.getComputedStyle(child).display === 'none')) child = child.previousElementSibling
                return child
            }
            let last = lastContent(doc.body)
            while (last) {
                tail = Math.max(tail, px(doc.defaultView.getComputedStyle(last), 'marginBottom'))
                last = lastContent(last)
            }
            const content = Math.max(bounds.height, bounds.bottom + doc.defaultView.scrollY)
            const extra = tail + px(body, 'paddingBottom') + px(root, 'paddingBottom')
            const ceiling = Math.max(48, Math.min(this.host.innerHeight * .45, 360, this.host.innerHeight - 24))
            const height = Math.ceil(Math.min(ceiling, Math.max(48, content + extra + 4)))
            if (this.dialog.style.height !== `${height}px`) this.dialog.style.height = `${height}px`
        })
    }
    #applySurface(element) {
        const appearance = this.snapshot()
        const style = element.style
        style.setProperty('font-size', `${appearance.fontSize}px`, 'important')
        style.setProperty('color', appearance.foregroundColor, 'important')
        style.setProperty('background-color', rgba(appearance.backgroundColor, appearance.backgroundOpacity), 'important')
        const blur = appearance.blur ? `blur(${appearance.blur}px)` : 'none'
        style.setProperty('backdrop-filter', blur, 'important')
        style.setProperty('-webkit-backdrop-filter', blur, 'important')
    }
    #applyKnownPopups() {
        for (const popup of this.dialog.ownerDocument.querySelectorAll('.rl-popup, [data-reader-footnote]')) {
            this.#applySurface(popup)
            if (popup.matches('.rl-popup')) {
                for (const button of popup.querySelectorAll('button')) button.style.setProperty('color', 'inherit', 'important')
            }
        }
    }
    applyDocument(doc) {
        if (!doc?.body) return
        let original = this.#originals.get(doc)
        if (!original) {
            const elements = [...doc.querySelectorAll('html, body, body *')]
                .filter(element => !['SCRIPT', 'STYLE', 'SVG', 'IMG'].includes(element.tagName))
            const samples = elements.map(element => {
                const computed = doc.defaultView.getComputedStyle(element)
                return { element, font: parseFloat(computed.fontSize),
                    line: computed.lineHeight === 'normal' ? null : parseFloat(computed.lineHeight) }
            })
            const walker = doc.createTreeWalker(doc.body, 4)
            let text
            let base = 16
            while ((text = walker.nextNode())) {
                const parent = text.parentElement
                if (/[A-Za-zА-Яа-яЁё]/.test(text.textContent) && parent &&
                    !parent.closest('rt, sup, sub, script, style, [role="doc-backlink"]')) {
                    const measured = parseFloat(doc.defaultView.getComputedStyle(parent).fontSize)
                    if (measured > 0) { base = measured; break }
                }
            }
            original = { samples, base }
            this.#originals.set(doc, original)
        }
        const appearance = this.snapshot()
        const factor = appearance.fontSize / original.base
        for (const { element, font, line } of original.samples) {
            if (!element.isConnected) continue
            if (Number.isFinite(font)) element.style.setProperty('font-size', `${font * factor}px`, 'important')
            if (line !== null && Number.isFinite(line)) element.style.setProperty('line-height', `${line * factor}px`, 'important')
            element.style.setProperty('color', appearance.foregroundColor, 'important')
        }
        doc.documentElement.style.setProperty('background', 'transparent', 'important')
        doc.body.style.setProperty('background', 'transparent', 'important')
        this.#fitDocument(doc)
    }
    destroy() {
        this.#observer.disconnect(); this.#fitObserver?.disconnect()
        if (this.#fitFrame !== null) this.host.cancelAnimationFrame(this.#fitFrame)
        this.#fitDoc = null; this.#fitFrame = null; this.#view = null
    }
}
