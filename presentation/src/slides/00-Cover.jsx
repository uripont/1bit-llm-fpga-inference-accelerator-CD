import { Slide } from "../components/Slide";
import { FpgaActivityGraphic } from "../components/FpgaActivityGraphic";

export default function Cover() {
  return (
    <Slide className="cover-slide">
      <div className="cover-layout">
        <div className="cover-copy">
          <h1>1-bit LLM FPGA-based<br />{" "}inference accelerator</h1>
          <p className="cover-subtitle">From measured Bonsai bottlenecks to board-feasible hardware services.</p>
          <div className="cover-course">
            <img
              src={`${import.meta.env.BASE_URL}images/polimi-logo.svg`}
              alt="Politecnico di Milano"
            />
            <p>Custom final project for the Design of Hardware Accelerators course at Politecnico di Milano.</p>
          </div>
          <div className="cover-meta">
            <span>Oriol Pont</span>
            <span>July 2026</span>
            <span>NEORV32 + Tang Nano 9K</span>
          </div>
        </div>
        <div className="cover-visual" aria-hidden="true">
          <FpgaActivityGraphic />
        </div>
      </div>
      <aside className="notes">This project starts from inference measurements, defines two hardware services, implements them, and evaluates both cycle gains and FPGA feasibility.</aside>
    </Slide>
  );
}
