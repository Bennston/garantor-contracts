import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    lang: 'tact',
    target: 'contracts/oracle_registry.tact',
    options: {
        debug: true,
    },
};
