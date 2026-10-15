/** Fixture files imported as text (`import csv from "./fixtures/x.csv?raw"`), resolved by Vite. */
declare module "*?raw" {
  const content: string;
  export default content;
}
