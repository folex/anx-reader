// Keep author font proportions, including absolute units and inherited sizes.
// Restore every old override before reading any computed value, then write once.
const snapshots = new WeakMap()
const properties = ['font-size', 'line-height']

export const applyBookFontScale = (doc, requestedScale, { lineSpacing } = {}) => {
    if (!doc?.documentElement) return
    for (const { element, original, hadStyle } of snapshots.get(doc) ?? []) {
        for (const [name, value, priority] of original) {
            if (value) element.style.setProperty(name, value, priority)
            else element.style.removeProperty(name)
        }
        if (!hadStyle && !element.style.length) element.removeAttribute('style')
    }
    snapshots.delete(doc)
    const number = Number(requestedScale)
    const scale = Number.isFinite(number) && number > 0 ? number : 1
    const spacingNumber = Number(lineSpacing)
    const spacing = Number.isFinite(spacingNumber) && spacingNumber > 0
        ? spacingNumber : null
    if (scale === 1 && spacing === null) return

    const elements = [doc.documentElement, ...doc.documentElement.querySelectorAll('*')]
        .filter(element => element.style)
    const entries = elements.map(element => {
        const computed = doc.defaultView.getComputedStyle(element)
        return {
            element,
            hadStyle: element.hasAttribute('style'),
            original: properties.map(name => [name,
                element.style.getPropertyValue(name),
                element.style.getPropertyPriority(name)]),
            font: parseFloat(computed.fontSize),
            // A fixed author line-height must grow with its font. `normal`
            // already follows the font automatically and must remain a keyword.
            line: parseFloat(computed.lineHeight),
        }
    })
    snapshots.set(doc, entries)
    for (const { element, font, line } of entries) {
        if (scale !== 1 && Number.isFinite(font))
            element.style.setProperty('font-size', `${font * scale}px`, 'important')
        // The UI spacing is an absolute unitless line-height, not a multiplier
        // of the author's line-height. Inline text must follow it too, otherwise
        // an author span with !important can still enlarge the paragraph's lines.
        const text = element.namespaceURI === 'http://www.w3.org/1999/xhtml'
            && !element.closest('rt,rp,sup,sub,svg,math,img,video,audio,canvas,iframe,object,embed,input,textarea,select,button')
        if (spacing !== null && text)
            element.style.setProperty('line-height', String(spacing), 'important')
        else if (scale !== 1 && Number.isFinite(line))
            element.style.setProperty('line-height', `${line * scale}px`, 'important')
    }
}
