<template>
    <div class="service-card-wrapper">
        <a
            :href="isCopyAction ? 'javascript:void(0)' : `/${service.path}/`"
            :target="!isCopyAction && openInNewTab ? '_blank' : undefined"
            :rel="!isCopyAction && openInNewTab ? 'noopener noreferrer' : undefined"
            class="service-card"
            :class="{ 'service-card--expanded': isCopyAction && expanded }"
            :id="`service-${service.path}`"
            @click="handleClick"
        >
            <div class="service-icon-wrapper">{{ service.icon }}</div>
            <div class="service-content">
                <div class="service-name">
                    <span class="service-status"></span>
                    {{ service.name }}
                </div>
                <div class="service-description" :style="descriptionStyle">
                    {{ displayDescription }}
                </div>
            </div>
            <div class="service-arrow">{{ isCopyAction ? '\u{1F4CB}' : '\u2192' }}</div>
        </a>
        <div
            v-if="isCopyAction && expanded"
            class="ssh-fallback"
            :class="{ 'ssh-fallback--error': copyStatus === 'error' }"
            :data-testid="`ssh-fallback-${service.path}`"
            @click.stop
        >
            <div class="ssh-fallback-hint" :data-testid="`ssh-fallback-hint-${service.path}`">
                {{ fallbackHint }}
            </div>
            <textarea
                ref="textareaRef"
                class="ssh-fallback-textarea"
                :data-testid="`ssh-fallback-textarea-${service.path}`"
                :value="sshCommand"
                readonly
                rows="3"
                spellcheck="false"
                wrap="soft"
                @click.stop="selectTextarea"
                @focus="selectTextarea"
            ></textarea>
        </div>
    </div>
</template>

<script setup lang="ts">
import { ref, computed, nextTick } from 'vue'
import type { DetectedService } from '../composables/useServiceDetection'
import { useLanguage } from '../composables/useLanguage'
import { useNewTab } from '../composables/useNewTab'

const props = defineProps<{
    service: DetectedService
}>()

const { lang } = useLanguage()
const { openInNewTab } = useNewTab()
const descriptionStyle = ref<Record<string, string>>({})
const expanded = ref(false)
const copyStatus = ref<'idle' | 'success' | 'error'>('idle')
const textareaRef = ref<HTMLTextAreaElement | null>(null)
let resetTimer: ReturnType<typeof setTimeout> | null = null

const isCopyAction = computed(() => props.service.action === 'copy-ssh')

const sshCommand = computed(() => {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
    const host = window.location.host
    const hostname = window.location.hostname
    const wsUrl = `${protocol}//${host}/${props.service.path}/`
    return `Host ${hostname}\n    ProxyCommand websocat --binary ${wsUrl}\n    User idekube`
})

const displayDescription = computed(() => {
    if (copyStatus.value === 'success') {
        return lang.value === 'zh' ? '\u5DF2\u590D\u5236 ProxyCommand!' : 'ProxyCommand Copied!'
    }
    if (copyStatus.value === 'error') {
        return lang.value === 'zh'
            ? '\u81EA\u52A8\u590D\u5236\u5931\u8D25\uFF0C\u8BF7\u4ECE\u4E0B\u65B9\u6587\u672C\u6846\u624B\u52A8\u590D\u5236'
            : 'Auto-copy failed \u2014 copy manually from the box below'
    }
    return props.service.description
})

const fallbackHint = computed(() => {
    if (copyStatus.value === 'error') {
        return lang.value === 'zh'
            ? '\u70B9\u51FB\u6587\u672C\u6846\u9009\u4E2D\u5168\u90E8\uFF0C\u6309 Ctrl/\u2318+C \u590D\u5236\uFF1A'
            : 'Click the box to select all, then press Ctrl/\u2318+C to copy:'
    }
    return lang.value === 'zh'
        ? '\u82E5\u81EA\u52A8\u590D\u5236\u4E0D\u53EF\u7528\uFF0C\u53EF\u4ECE\u4E0B\u65B9\u624B\u52A8\u9009\u53D6\u590D\u5236\uFF1A'
        : 'If auto-copy is unavailable, select and copy manually below:'
})

function handleClick(e: MouseEvent) {
    if (!isCopyAction.value) return

    e.preventDefault()
    expanded.value = true

    if (resetTimer !== null) {
        clearTimeout(resetTimer)
        resetTimer = null
    }

    void runCopy()
}

async function runCopy() {
    try {
        await copyToClipboard(sshCommand.value)
        copyStatus.value = 'success'
        descriptionStyle.value = { color: 'var(--primary)' }
        resetTimer = setTimeout(() => {
            if (copyStatus.value === 'success') {
                copyStatus.value = 'idle'
                descriptionStyle.value = {}
            }
            resetTimer = null
        }, 2000)
    } catch (err) {
        console.error('Failed to copy text: ', err)
        copyStatus.value = 'error'
        descriptionStyle.value = { color: 'var(--danger)' }
        await nextTick()
        if (textareaRef.value) {
            textareaRef.value.focus()
            textareaRef.value.select()
        }
    }
}

function selectTextarea() {
    textareaRef.value?.select()
}

async function copyToClipboard(text: string): Promise<void> {
    if (navigator.clipboard && window.isSecureContext) {
        return navigator.clipboard.writeText(text)
    }
    const textarea = document.createElement('textarea')
    textarea.value = text
    textarea.style.position = 'fixed'
    textarea.style.top = '-9999px'
    textarea.style.left = '-9999px'
    textarea.setAttribute('readonly', '')
    document.body.appendChild(textarea)
    textarea.select()
    try {
        // execCommand is deprecated but remains the only clipboard fallback for non-secure contexts (HTTP origins).
        // eslint-disable-next-line @typescript-eslint/no-deprecated
        const ok = document.execCommand('copy')
        if (!ok) throw new Error('execCommand copy returned false')
    } finally {
        document.body.removeChild(textarea)
    }
}
</script>

<style scoped>
.service-card-wrapper {
    display: flex;
    flex-direction: column;
}

.service-card {
    display: flex;
    align-items: center;
    padding: 20px 24px;
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    border-radius: 16px;
    text-decoration: none;
    color: inherit;
    transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
    cursor: pointer;
    position: relative;
    overflow: hidden;
}

.service-card--expanded {
    border-radius: 16px 16px 0 0;
    border-bottom-color: transparent;
}

.service-card::before {
    content: "";
    position: absolute;
    top: 0;
    left: 0;
    width: 4px;
    height: 100%;
    background: linear-gradient(135deg, var(--primary), var(--accent));
    transform: scaleY(0);
    transition: transform 0.3s ease;
}

.service-card:hover {
    transform: translateX(4px);
    box-shadow: 0 12px 24px var(--shadow-hover);
    border-color: var(--primary);
}

.service-card--expanded:hover {
    transform: none;
}

.service-card:hover::before {
    transform: scaleY(1);
}

.ssh-fallback {
    padding: 16px 24px 20px;
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    border-top: 1px dashed var(--border);
    border-radius: 0 0 16px 16px;
    animation: ssh-fallback-reveal 0.2s ease-out;
}

.ssh-fallback--error {
    border-color: var(--danger);
}

.ssh-fallback-hint {
    font-size: 0.8125rem;
    color: var(--text-secondary);
    margin-bottom: 8px;
    line-height: 1.4;
}

.ssh-fallback--error .ssh-fallback-hint {
    color: var(--danger);
}

.ssh-fallback-textarea {
    width: 100%;
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
    font-size: 0.8125rem;
    line-height: 1.45;
    color: var(--text-primary);
    background: var(--bg-card);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 10px 12px;
    resize: none;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    field-sizing: content;
    min-height: calc(3 * 1.45em + 20px);
    overflow: hidden;
    cursor: text;
}

.ssh-fallback-textarea:focus {
    outline: none;
    border-color: var(--primary);
    box-shadow: 0 0 0 3px color-mix(in srgb, var(--primary) 25%, transparent);
}

@keyframes ssh-fallback-reveal {
    from {
        opacity: 0;
        transform: translateY(-4px);
    }
    to {
        opacity: 1;
        transform: translateY(0);
    }
}

.service-icon-wrapper {
    font-size: 2rem;
    margin-right: 20px;
    filter: grayscale(0.3);
    transition: all 0.3s ease;
}

.service-card:hover .service-icon-wrapper {
    filter: grayscale(0);
    transform: scale(1.1);
}

.service-content {
    flex: 1;
}

.service-name {
    font-size: 1.25rem;
    font-weight: 600;
    color: var(--text-primary);
    margin-bottom: 4px;
    display: flex;
    align-items: center;
    gap: 8px;
}

.service-status {
    display: inline-block;
    width: 8px;
    height: 8px;
    background: var(--accent);
    border-radius: 50%;
    animation: pulse 2s ease-in-out infinite;
}

@keyframes pulse {
    0%,
    100% {
        opacity: 1;
    }
    50% {
        opacity: 0.5;
    }
}

.service-description {
    font-size: 0.875rem;
    color: var(--text-tertiary);
    font-weight: 400;
}

.service-arrow {
    color: var(--text-tertiary);
    font-size: 1.25rem;
    transition: all 0.3s ease;
    opacity: 0;
}

.service-card:hover .service-arrow {
    opacity: 1;
    transform: translateX(4px);
}

@media (max-width: 480px) {
    .service-card {
        padding: 16px 20px;
    }

    .service-icon-wrapper {
        font-size: 1.5rem;
        margin-right: 16px;
    }

    .service-name {
        font-size: 1.125rem;
    }
}
</style>
