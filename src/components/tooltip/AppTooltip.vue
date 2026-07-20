<script setup lang="ts">
import { nextTick, ref, watch } from 'vue'
import styles from './AppTooltip.module.css'

type TooltipPlacement =
  | 'top'
  | 'top-start'
  | 'top-end'
  | 'bottom'
  | 'bottom-start'
  | 'bottom-end'

const props = withDefaults(
  defineProps<{
    label: string
    shortcut?: string
    placement?: TooltipPlacement
  }>(),
  {
    shortcut: undefined,
    placement: 'top',
  },
)

const wrapRef = ref<HTMLElement | null>(null)
const tooltipRef = ref<HTMLElement | null>(null)
const actualPlacement = ref<TooltipPlacement>(props.placement)
const tooltipStyle = ref<Record<string, string>>({})
const positioned = ref(false)

watch(
  () => props.placement,
  (placement) => {
    actualPlacement.value = placement
  },
)

function flipPlacement(placement: TooltipPlacement): TooltipPlacement {
  return placement.startsWith('top')
    ? (placement.replace('top', 'bottom') as TooltipPlacement)
    : (placement.replace('bottom', 'top') as TooltipPlacement)
}

async function updatePlacement() {
  positioned.value = false
  actualPlacement.value = props.placement
  await nextTick()

  const wrap = wrapRef.value
  const tooltip = tooltipRef.value

  if (!wrap || !tooltip) {
    return
  }

  const gap = 3
  const margin = 6
  const wrapRect = wrap.getBoundingClientRect()
  const tooltipRect = tooltip.getBoundingClientRect()
  const above = wrapRect.top - tooltipRect.height - gap
  const below = wrapRect.bottom + gap

  let nextPlacement = props.placement

  if (props.placement.startsWith('top') && above < margin) {
    nextPlacement = flipPlacement(props.placement)
  }

  if (props.placement.startsWith('bottom') && below + tooltipRect.height > window.innerHeight - margin) {
    nextPlacement = flipPlacement(props.placement)
  }

  actualPlacement.value = nextPlacement

  const isTop = nextPlacement.startsWith('top')
  const alignEnd = nextPlacement.endsWith('end')
  const alignStart = nextPlacement.endsWith('start')
  const preferredLeft = alignEnd
    ? wrapRect.right
    : alignStart
      ? wrapRect.left
      : wrapRect.left + wrapRect.width / 2
  const transformX = alignEnd ? '-100%' : alignStart ? '0' : '-50%'
  const left = Math.max(margin, Math.min(preferredLeft, window.innerWidth - margin))

  tooltipStyle.value = {
    '--tooltip-left': `${left}px`,
    '--tooltip-top': `${isTop ? above : below}px`,
    '--tooltip-x': transformX,
  }
  positioned.value = true
}
</script>

<template>
  <span
    ref="wrapRef"
    :class="styles.wrap"
    :data-placement="actualPlacement"
    :data-positioned="positioned"
    @mouseenter="updatePlacement"
    @focusin="updatePlacement"
  >
    <slot />
    <span ref="tooltipRef" :class="styles.tooltip" :style="tooltipStyle" role="tooltip">
      <span>{{ label }}</span>
      <kbd v-if="shortcut">{{ shortcut }}</kbd>
    </span>
  </span>
</template>
