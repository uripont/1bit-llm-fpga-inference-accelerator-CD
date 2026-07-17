const signalPaths = [
  { id: "signal-a", tone: "blue", d: "M 22 116 H 128 L 214 190 H 360", duration: "3.6s", begin: "-1.7s" },
  { id: "signal-b", tone: "rust", d: "M 16 174 H 112 L 208 248 H 322", duration: "4.4s", begin: "-3.1s" },
  { id: "signal-c", tone: "blue", d: "M 30 250 H 138 L 218 292 H 350", duration: "3.1s", begin: "-0.8s" },
  { id: "signal-d", tone: "blue", d: "M 54 354 H 150 L 236 320 H 380", duration: "4s", begin: "-2.4s" },
  { id: "signal-e", tone: "blue", d: "M 430 198 H 572 L 646 126 H 744", duration: "3.4s", begin: "-1.2s" },
  { id: "signal-f", tone: "rust", d: "M 478 252 H 596 L 664 210 H 750", duration: "4.7s", begin: "-2.8s" },
  { id: "signal-g", tone: "blue", d: "M 485 304 H 610 L 682 354 H 748", duration: "3.8s", begin: "-0.3s" },
  { id: "signal-h", tone: "rust", d: "M 430 350 H 576 L 650 430 H 740", duration: "4.2s", begin: "-3.6s" },
];

const tileColumns = 7;
const tileRows = 5;
const fabricCorners = {
  topLeft: { x: 278, y: 216 },
  topRight: { x: 425, y: 184 },
  bottomRight: { x: 516, y: 285 },
  bottomLeft: { x: 367, y: 321 },
};
const fabricSurfacePoints = "278,216 425,184 516,285 367,321";
const chipTopPoints = "238,211 435,167 552,298 357,346";
const chipFramePoints = "260.42,218.29 430.74,180.25 529.76,291.12 361.19,332.61";
const mountRailCorners = [
  { x: 249.21, y: 214.64 },
  { x: 432.87, y: 173.62 },
  { x: 540.88, y: 294.56 },
  { x: 359.1, y: 339.3 },
];
const mountRailPoints = mountRailCorners.map(({ x, y }) => `${x},${y}`).join(" ");
const mountCirclePositions = [
  { x: 259, y: 216 },
  { x: 435, y: 178 },
  { x: 535, y: 292 },
  { x: 359, y: 334 },
];
const gridMarginU = 0.065;
const gridMarginV = 0.065;
const gridGapU = 0.014;
const gridGapV = 0.018;

function surfacePoint(u, v) {
  const { topLeft, topRight, bottomRight, bottomLeft } = fabricCorners;

  return {
    x:
      (1 - u) * (1 - v) * topLeft.x +
      u * (1 - v) * topRight.x +
      u * v * bottomRight.x +
      (1 - u) * v * bottomLeft.x,
    y:
      (1 - u) * (1 - v) * topLeft.y +
      u * (1 - v) * topRight.y +
      u * v * bottomRight.y +
      (1 - u) * v * bottomLeft.y,
  };
}

function surfaceQuadPoints(u0, v0, u1, v1) {
  return [
    surfacePoint(u0, v0),
    surfacePoint(u1, v0),
    surfacePoint(u1, v1),
    surfacePoint(u0, v1),
  ]
    .map(({ x, y }) => `${x},${y}`)
    .join(" ");
}

function tileGeometry(column, row) {
  const cellU = (1 - gridMarginU * 2) / tileColumns;
  const cellV = (1 - gridMarginV * 2) / tileRows;
  const u0 = gridMarginU + column * cellU + gridGapU / 2;
  const u1 = gridMarginU + (column + 1) * cellU - gridGapU / 2;
  const v0 = gridMarginV + row * cellV + gridGapV / 2;
  const v1 = gridMarginV + (row + 1) * cellV - gridGapV / 2;
  const center = surfacePoint((u0 + u1) / 2, (v0 + v1) / 2);

  return {
    points: surfaceQuadPoints(u0, v0, u1, v1),
    centerX: center.x,
    centerY: center.y,
  };
}

const scanBandPoints = surfaceQuadPoints(0.03, -0.16, 0.97, 0.06);

const computeTiles = Array.from({ length: tileColumns * tileRows }, (_, index) => {
  const column = index % tileColumns;
  const row = Math.floor(index / tileColumns);
  const isRust = (column + row * 2) % 7 === 0 || (column === 4 && row === 3);
  const isCore = column >= 2 && column <= 4 && row >= 1 && row <= 3;
  const geometry = tileGeometry(column, row);

  return {
    index,
    ...geometry,
    tone: isRust ? "rust" : isCore ? "core" : "blue",
    delay: `-${((index * 0.29) % 2.6).toFixed(2)}s`,
  };
});

const rightPins = Array.from({ length: 11 }, (_, index) => ({
  x1: 374 + index * 15.2,
  y1: 342 - index * 3.7,
  x2: 382 + index * 15.2,
  y2: 361 - index * 3.7,
}));

export function FpgaActivityGraphic() {
  return (
    <div
      className="fpga-activity-component"
      style={{ width: "100%", height: "100%", minHeight: 0, display: "grid", placeItems: "center" }}
    >
      <svg
        className="fpga-activity-svg"
        viewBox="0 0 760 520"
        role="img"
        aria-label="Animated FPGA processing parallel data"
        preserveAspectRatio="xMidYMid meet"
        style={{ display: "block", width: "100%", height: "100%", maxWidth: 760, overflow: "visible" }}
      >
        <style>{`
          .fpga-activity-svg {
            --fpga-ink: #142238;
            --fpga-muted: #718096;
            --fpga-blue: #335c91;
            --fpga-blue-soft: #eaf0fb;
            --fpga-rust: #a84d32;
            --fpga-rust-soft: #faece6;
          }

          .fpga-orbit {
            animation: fpga-orbit-turn 24s linear infinite;
            transform-box: fill-box;
            transform-origin: center;
          }

          .fpga-trace-active {
            animation: fpga-trace-run 2.8s linear infinite;
          }

          .fpga-packet {
            filter: url(#packet-glow);
          }

          .fpga-tile {
            animation: fpga-tile-work 2.7s ease-in-out var(--tile-delay) infinite;
          }

          .fpga-tile-light {
            animation: fpga-light-work 2.7s ease-in-out var(--tile-delay) infinite;
          }

          .fpga-scan-band {
            animation: fpga-fabric-scan 3.6s ease-in-out infinite;
          }

          .fpga-chip-group {
            animation: fpga-chip-float 6s ease-in-out infinite;
            transform-origin: 390px 275px;
          }

          @keyframes fpga-trace-run {
            to { stroke-dashoffset: -42; }
          }

          @keyframes fpga-orbit-turn {
            to { transform: rotate(360deg); }
          }

          @keyframes fpga-tile-work {
            0%, 100% { opacity: 0.42; }
            42% { opacity: 1; }
            62% { opacity: 0.68; }
          }

          @keyframes fpga-light-work {
            0%, 100% { opacity: 0.08; }
            42% { opacity: 0.92; }
            62% { opacity: 0.24; }
          }

          @keyframes fpga-fabric-scan {
            0%, 8% { opacity: 0; transform: translate(-22px, -36px); }
            35%, 65% { opacity: 0.46; }
            92%, 100% { opacity: 0; transform: translate(50px, 78px); }
          }

          @keyframes fpga-chip-float {
            0%, 100% { transform: translateY(0); }
            50% { transform: translateY(-4px); }
          }

          @media (prefers-reduced-motion: reduce) {
            .fpga-orbit,
            .fpga-trace-active,
            .fpga-tile,
            .fpga-tile-light,
            .fpga-scan-band,
            .fpga-chip-group {
              animation: none !important;
            }

            .fpga-packet { display: none; }
          }
        `}</style>

        <defs>
          <linearGradient id="chip-top" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stopColor="#243b5a" />
            <stop offset="0.55" stopColor="#142238" />
            <stop offset="1" stopColor="#0d1828" />
          </linearGradient>
          <linearGradient id="fabric-base" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stopColor="#f7f9fc" />
            <stop offset="0.6" stopColor="#eaf0fb" />
            <stop offset="1" stopColor="#d8e3f4" />
          </linearGradient>
          <linearGradient id="scan-gradient" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0" stopColor="#335c91" stopOpacity="0" />
            <stop offset="0.5" stopColor="#ffffff" stopOpacity="0.95" />
            <stop offset="1" stopColor="#a84d32" stopOpacity="0" />
          </linearGradient>
          <radialGradient id="halo-gradient">
            <stop offset="0" stopColor="#335c91" stopOpacity="0.12" />
            <stop offset="0.58" stopColor="#eaf0fb" stopOpacity="0.12" />
            <stop offset="1" stopColor="#ffffff" stopOpacity="0" />
          </radialGradient>
          <filter id="chip-shadow" x="-30%" y="-60%" width="160%" height="220%">
            <feGaussianBlur stdDeviation="13" />
          </filter>
          <filter id="packet-glow" x="-300%" y="-300%" width="700%" height="700%">
            <feGaussianBlur stdDeviation="2.2" result="blur" />
            <feMerge>
              <feMergeNode in="blur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
          <clipPath id="fabric-clip">
            <polygon points={fabricSurfacePoints} />
          </clipPath>
        </defs>

        <ellipse cx="382" cy="265" rx="310" ry="220" fill="url(#halo-gradient)" />
        <ellipse
          className="fpga-orbit"
          cx="382"
          cy="260"
          rx="278"
          ry="186"
          fill="none"
          stroke="#d8e3f4"
          strokeWidth="1.2"
          strokeDasharray="3 14"
          vectorEffect="non-scaling-stroke"
        />

        <g fill="none" strokeLinecap="round" strokeLinejoin="round">
          {signalPaths.map((signal) => (
            <g key={signal.id}>
              <path
                d={signal.d}
                stroke={signal.tone === "rust" ? "#ead0c7" : "#c3d2e7"}
                strokeWidth="2"
                vectorEffect="non-scaling-stroke"
              />
              <path
                className="fpga-trace-active"
                d={signal.d}
                stroke={signal.tone === "rust" ? "#a84d32" : "#335c91"}
                strokeWidth="1.4"
                strokeDasharray="2 12 18 10"
                vectorEffect="non-scaling-stroke"
                style={{ animationDelay: signal.begin }}
              />
              <circle
                className="fpga-packet"
                r={signal.tone === "rust" ? 4.3 : 3.8}
                fill={signal.tone === "rust" ? "#a84d32" : "#335c91"}
                stroke="#ffffff"
                strokeWidth="1.4"
              >
                <animateMotion
                  path={signal.d}
                  dur={signal.duration}
                  begin={signal.begin}
                  repeatCount="indefinite"
                  calcMode="spline"
                  keyTimes="0;1"
                  keySplines="0.4 0 0.2 1"
                />
                <animate
                  attributeName="opacity"
                  values="0;1;1;0"
                  keyTimes="0;0.12;0.88;1"
                  dur={signal.duration}
                  begin={signal.begin}
                  repeatCount="indefinite"
                />
              </circle>
            </g>
          ))}
        </g>

        <ellipse cx="392" cy="377" rx="183" ry="34" fill="#142238" opacity="0.17" filter="url(#chip-shadow)" />

        <g className="fpga-chip-group">
          {rightPins.map((pin, index) => (
            <line key={`right-pin-${index}`} {...pin} stroke="#a84d32" strokeWidth="4.5" strokeLinecap="round" />
          ))}

          <polygon points="238,211 357,346 357,377 236,241" fill="#0b1523" />
          <polygon points="357,346 552,298 552,329 357,377" fill="#101d2f" />
          <polygon points={chipTopPoints} fill="url(#chip-top)" stroke="#142238" strokeWidth="4" />
          <polygon points={chipFramePoints} fill="#0b1728" stroke="#5f7390" strokeWidth="2" />
          <polygon className="fpga-fabric-surface" points={fabricSurfacePoints} fill="url(#fabric-base)" stroke="#335c91" strokeWidth="2.2" />

          <g clipPath="url(#fabric-clip)">
            {computeTiles.map((tile) => {
              const fill = tile.tone === "rust" ? "#faece6" : tile.tone === "core" ? "#d8e3f4" : "#eef3fb";
              const stroke = tile.tone === "rust" ? "#a84d32" : "#335c91";
              return (
                <g key={tile.index} style={{ "--tile-delay": tile.delay }}>
                  <polygon
                    className="fpga-tile"
                    points={tile.points}
                    fill={fill}
                    stroke={stroke}
                    strokeWidth={tile.tone === "core" ? 1.8 : 1.2}
                    vectorEffect="non-scaling-stroke"
                  />
                  <circle
                    className="fpga-tile-light"
                    cx={tile.centerX}
                    cy={tile.centerY}
                    r={tile.tone === "core" ? 2.7 : 1.7}
                    fill={tile.tone === "rust" ? "#a84d32" : "#335c91"}
                  />
                </g>
              );
            })}

            <polygon
              className="fpga-scan-band"
              points={scanBandPoints}
              fill="url(#scan-gradient)"
              opacity="0"
            />
          </g>

          <polygon points={mountRailPoints} fill="none" stroke="#7890b0" strokeWidth="1" opacity="0.7" />
          {mountCirclePositions.map(({ x, y }, index) => (
            <circle
              key={`mount-${index}`}
              cx={x}
              cy={y}
              r="5"
              fill="#07111f"
              stroke="#718096"
              strokeWidth="1.5"
            />
          ))}
        </g>
      </svg>
    </div>
  );
}
