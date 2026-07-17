export function Slide({
  children,
  className = "",
  title,
  subtitle,
  source,
  ...props
}) {
  return (
    <section className={`project-slide ${className}`} {...props}>
      <div className={`slide-shell ${source ? "has-source" : ""}`}>
        <div className="slide-content">
          {title && (
            <header className="slide-header">
              <h2>{title}</h2>
              {subtitle && <p className="subtitle">{subtitle}</p>}
            </header>
          )}
          <div className="slide-body">{children}</div>
        </div>
        {source && <footer className="slide-source">{source}</footer>}
      </div>
    </section>
  );
}

export function Source({ href, children }) {
  return (
    <a href={href} target="_blank" rel="noreferrer">
      {children}
    </a>
  );
}

export function Metric({ value, label, tone = "ink", detail }) {
  return (
    <div className={`metric tone-${tone}`}>
      <strong>{value}</strong>
      <span>{label}</span>
      {detail && <small>{detail}</small>}
    </div>
  );
}

export function ModelScale({ value, detail, size = "large", showCopy = true, activeCells: activeCellOverride }) {
  const cellCount = 800;
  const activeCells = activeCellOverride ?? (size === "large" ? cellCount : 0);

  return (
    <div className={`model-scale model-scale-${size}`}>
      {showCopy && (
        <div className="model-scale-copy">
          <span className="mono">MODEL SIZE</span>
          <strong>{value}</strong>
        </div>
      )}
      <div className="model-scale-cells" aria-hidden="true">
        {Array.from({ length: cellCount }, (_, index) => (
          <i
            className={[
              index < activeCells ? "is-active" : "",
              size === "toy" && index === 0 ? "is-partial" : "",
            ].filter(Boolean).join(" ")}
            key={index}
          />
        ))}
      </div>
      {detail && <small>{detail}</small>}
    </div>
  );
}

export function Flow({ items, compact = false }) {
  return (
    <div className={`flow ${compact ? "flow-compact" : ""}`}>
      {items.map((item, index) => (
        <div className="flow-item" key={item.title ?? item}>
          <div className={`flow-box ${item.tone ? `tone-${item.tone}` : ""}`}>
            <strong>{item.title ?? item}</strong>
            {item.detail && <span>{item.detail}</span>}
          </div>
          {index < items.length - 1 && <span className="flow-arrow">→</span>}
        </div>
      ))}
    </div>
  );
}

export function BarCompare({ rows, max, unit = "cycles" }) {
  const limit = max ?? Math.max(...rows.flatMap((row) => row.values.map((item) => item.value)));
  return (
    <div className="bar-compare">
      {rows.map((row) => (
        <div className="bar-row" key={row.label}>
          <div className="bar-row-label">{row.label}</div>
          <div className="bar-row-series">
            {row.values.map((item) => (
              <div className="bar-line" key={item.label}>
                <span className="bar-label">{item.label}</span>
                <div className="bar-track">
                  <div
                    className={`bar-fill tone-${item.tone ?? "ink"}`}
                    style={{ width: `${Math.max((item.value / limit) * 100, 1.5)}%` }}
                  />
                </div>
                <strong>{item.display ?? item.value.toLocaleString()} {unit}</strong>
              </div>
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}

export function Callout({ children, tone = "mint", label }) {
  return (
    <div className={`callout tone-${tone}`}>
      <p>{label && <strong>{label}: </strong>}{children}</p>
    </div>
  );
}
