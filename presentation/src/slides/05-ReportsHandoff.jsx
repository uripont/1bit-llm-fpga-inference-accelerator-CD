import { Slide } from "../components/Slide";

const reports = [
  {
    label: "Benchmark methodology and bottlenecks",
    folder: "benchmark",
    pageCount: 5,
    href: "https://github.com/uripont/1bit-llm-fpga-inference-accelerator-CD/blob/main/docs/01-bonsai-bottleneck-benchmark.pdf",
  },
  {
    label: "Accelerator hardware blueprint",
    folder: "architecture",
    pageCount: 9,
    href: "https://github.com/uripont/1bit-llm-fpga-inference-accelerator-CD/blob/main/docs/02-bonsai-accelerator-hardware-blueprint.pdf",
  },
  {
    label: "Implementation and evaluation",
    folder: "evaluation",
    pageCount: 2,
    href: "https://github.com/uripont/1bit-llm-fpga-inference-accelerator-CD/blob/main/docs/03-bonsai-accelerator-implementation-evaluation.pdf",
  },
];

export default function ReportsHandoff() {
  return (
    <Slide
      className="reports-handoff-slide"
      title="Visit the reports of the stages to learn more about the project"
    >
      <div className="report-groups" aria-label="Project stage reports">
        {reports.map((report, reportIndex) => {
          const midpoint = (report.pageCount - 1) / 2;

          return (
            <a
              className="report-page-group"
              href={report.href}
              target="_blank"
              rel="noreferrer"
              aria-label={`Open ${report.label} PDF on GitHub`}
              key={report.href}
              style={{ "--group-delay": `${80 + reportIndex * 70}ms` }}
            >
              {Array.from({ length: report.pageCount }, (_, pageIndex) => {
                const distance = pageIndex - midpoint;

                return (
                  <img
                    className="report-group-page"
                    key={`${report.folder}-${pageIndex + 1}`}
                    src={`${import.meta.env.BASE_URL}report-previews/${report.folder}/page-${pageIndex + 1}.jpg`}
                    alt=""
                    aria-hidden="true"
                    loading="eager"
                    style={{
                      "--page-x": `${distance * 10}px`,
                      "--page-mobile-x": `${distance * 4}px`,
                      "--page-y": `${Math.abs(distance) * 1.2}px`,
                      "--page-rotate": `${distance * 0.85}deg`,
                      "--hover-x": `${distance * 17}px`,
                      "--hover-mobile-x": `${distance * 7}px`,
                      "--hover-y": `${-Math.abs(distance) * 2.4}px`,
                      "--hover-rotate": `${distance * 1.65}deg`,
                      "--page-z": `${report.pageCount - pageIndex}`,
                    }}
                  />
                );
              })}
            </a>
          );
        })}
      </div>

      <aside className="notes">Open the report for the stage whose methods, decisions or evidence you want to inspect in detail.</aside>
    </Slide>
  );
}
