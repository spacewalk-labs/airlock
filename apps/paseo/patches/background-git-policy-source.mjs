// Single policy source for the generated snapshot/fetch and reconciliation overlays.
export const BACKGROUND_GIT_SCALE_ENV = "PASEO_BACKGROUND_GIT_SAMPLE_SCALE";
export const DEFAULT_BACKGROUND_GIT_SCALE = 20;

export function renderBackgroundGitScale(prefix) {
    return `const ${prefix}ScaleValue = Number(process.env.${BACKGROUND_GIT_SCALE_ENV} ?? ${DEFAULT_BACKGROUND_GIT_SCALE});
const ${prefix}Scale = Number.isInteger(${prefix}ScaleValue) && ${prefix}ScaleValue > 0
    ? ${prefix}ScaleValue : ${DEFAULT_BACKGROUND_GIT_SCALE};`;
}
