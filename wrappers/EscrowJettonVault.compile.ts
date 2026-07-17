import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    lang: 'tact',
    target: 'contracts/escrow_jetton_vault.tact',
    options: {
        debug: true,
    },
};
