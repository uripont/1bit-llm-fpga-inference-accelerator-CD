export function BottleneckChart() {
  const points = [
    { ctx: "128", q1: 88.24, attention: 4.9 },
    { ctx: "512", q1: 81.75, attention: 12.7 },
    { ctx: "2K", q1: 63.96, attention: 31.74 },
    { ctx: "4K", q1: 49.86, attention: 46.93 },
    { ctx: "8K", q1: 31.33, attention: 63.11 },
    { ctx: "16K", q1: 20.12, attention: 78.16 },
    { ctx: "32K", q1: 10.7, attention: 88.01 },
  ];

  const width = 820;
  const height = 360;
  const x = (index) => 72 + (index * 700) / (points.length - 1);
  const y = (value) => 310 - value * 2.55;
  const line = (key) => points.map((point, index) => `${x(index)},${y(point[key])}`).join(" ");

  return (
    <div className="chart-frame" aria-label="Prefill bottleneck share by prompt length">
      <svg viewBox={`0 0 ${width} ${height}`} role="img">
        {[0, 25, 50, 75, 100].map((tick) => (
          <g key={tick}>
            <line x1="64" x2="790" y1={y(tick)} y2={y(tick)} className="grid-line" />
            <text x="52" y={y(tick) + 6} textAnchor="end" className="axis-label">{tick}%</text>
          </g>
        ))}
        <polyline points={line("q1")} className="chart-line chart-q1" />
        <polyline points={line("attention")} className="chart-line chart-attention" />
        {points.map((point, index) => (
          <g key={point.ctx}>
            <circle cx={x(index)} cy={y(point.q1)} r="6" className="point-q1" />
            <circle cx={x(index)} cy={y(point.attention)} r="6" className="point-attention" />
            <text x={x(index)} y="342" textAnchor="middle" className="axis-label">{point.ctx}</text>
          </g>
        ))}
      </svg>
      <div className="chart-legend">
        <span><i className="legend-q1" /> Q1_0 matrix work</span>
        <span><i className="legend-attention" /> Attention / key-value</span>
      </div>
    </div>
  );
}

export function ResourceGauge({ label, used, total, tone = "ink", note }) {
  const percentage = Math.round((used / total) * 100);
  return (
    <div className="resource-gauge">
      <div className="resource-label"><strong>{label}</strong><span>{used.toLocaleString()} / {total.toLocaleString()}</span></div>
      <div className="resource-track"><div className={`resource-fill tone-${tone}`} style={{ width: `${Math.min(percentage, 100)}%` }} /></div>
      <div className="resource-note"><strong>{percentage}%</strong><span>{note}</span></div>
    </div>
  );
}
