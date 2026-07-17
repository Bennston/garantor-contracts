import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    lang: 'tact',
    target: 'contracts/marketplace_listing.tact',
    options: {
        debug: true,
    },
};
