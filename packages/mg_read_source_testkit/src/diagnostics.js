/**
 * 数据源测试库的有界诊断模型。
 *
 * 职责：生成稳定错误码、阶段和小型摘要。
 */
const maximumDiagnosticCharacters = 360;

export class SourceTestFailure extends Error {
  constructor(code, stage, summary = {}) {
    const compact = compactJson(summary);
    super(`${code} at ${stage}${compact === '{}' ? '' : `: ${compact}`}`);
    this.name = 'SourceTestFailure';
    this.code = code;
    this.stage = stage;
    this.summary = Object.freeze({ ...summary });
  }

  toJSON() {
    return Object.freeze({
      name: this.name,
      code: this.code,
      stage: this.stage,
      summary: this.summary,
    });
  }
}

export function failureFromCause(code, stage, error) {
  return new SourceTestFailure(code, stage, causeSummary(error));
}

export function causeSummary(error) {
  return Object.freeze({
    causeName: typeof error?.name === 'string' ? error.name.slice(0, 80) : 'Error',
    ...(typeof error?.code === 'string' ? { causeCode: error.code.slice(0, 80) } : {}),
    ...(error instanceof Error ? { causeMessage: error.message.slice(0, maximumDiagnosticCharacters) } : {}),
  });
}

function compactJson(value) {
  const encoded = JSON.stringify(value);
  return encoded.length <= maximumDiagnosticCharacters
    ? encoded
    : `${encoded.slice(0, maximumDiagnosticCharacters - 3)}...`;
}
