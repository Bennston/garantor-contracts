import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    lang: 'tact',
    target: 'contracts/escrow_jetton_vault_milestone.tact',
    options: { debug: true },
};
