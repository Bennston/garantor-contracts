import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    lang: 'tact',
    target: 'contracts/escrow_jetton_factory.tact',
    options: {
        debug: true,
    },
};
