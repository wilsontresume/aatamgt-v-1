import { Component, Input } from '@angular/core';
import { CommonModule } from '@angular/common';

export interface ChartRow {
  label: string;
  value: number;
}

/** Hand-rolled SVG-free bar chart: no chart library dependency. */
@Component({
  selector: 'app-bar-chart',
  standalone: true,
  imports: [CommonModule],
  templateUrl: './bar-chart.html',
  styleUrl: './bar-chart.scss',
})
export class BarChart {
  @Input({ required: true }) rows: ChartRow[] = [];
  @Input() unit = '';

  get max(): number {
    return Math.max(1, ...this.rows.map((r) => r.value));
  }

  height(row: ChartRow): number {
    return Math.max(row.value > 0 ? 3 : 0, (row.value / this.max) * 100);
  }
}
