import type { Config } from 'jest';

const config: Config = {
    preset: 'ts-jest',
    testEnvironment: 'node',
    roots: ['<rootDir>/tests'],
    testPathIgnorePatterns: ['/node_modules/', '/dist/'],
    maxWorkers: 1,
};

export default config;
