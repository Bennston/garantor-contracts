import { CompilerConfig } from "@ton/blueprint";

export const compile: CompilerConfig = {
  lang: "tact",
  target: "contracts/escrow_jetton_milestone_factory.tact",
  options: {
    debug: false,
  },
};
