<script>
import { format, parseISO } from 'date-fns';
import { required, url } from '@vuelidate/validators';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import MultiselectDropdown from 'shared/components/ui/MultiselectDropdown.vue';
import HelperTextPopup from 'dashboard/components/ui/HelperTextPopup.vue';
import { isValidURL } from '../helper/URLHelper';
import { getRegexp } from 'shared/helpers/Validators';
import { useVuelidate } from '@vuelidate/core';
import { emitter } from 'shared/helpers/mitt';

import NextButton from 'dashboard/components-next/button/Button.vue';

const DATE_FORMAT = 'yyyy-MM-dd';

export default {
  components: {
    MultiselectDropdown,
    HelperTextPopup,
    NextButton,
  },
  props: {
    label: { type: String, required: true },
    description: { type: String, default: '' },
    values: { type: Array, default: () => [] },
    value: { type: [String, Number, Boolean], default: '' },
    showActions: { type: Boolean, default: false },
    attributeType: { type: String, default: 'text' },
    attributeRegex: {
      type: String,
      default: null,
    },
    regexCue: { type: String, default: null },
    attributeKey: { type: String, required: true },
    contactId: { type: Number, default: null },
  },
  emits: ['update', 'delete', 'copy'],
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      isEditing: false,
      editedValue: null,
    };
  },
  computed: {
    displayValue() {
      if (this.isAttributeTypeDate) {
        return this.value
          ? new Date(this.value || new Date()).toLocaleDateString()
          : '---';
      }
      if (this.isAttributeTypeCheckbox) {
        return this.value === 'false' ? false : this.value;
      }
      return this.hasValue ? this.value : '---';
    },
    formattedValue() {
      return this.isAttributeTypeDate
        ? format(this.value ? new Date(this.value) : new Date(), DATE_FORMAT)
        : this.value;
    },
    listOptions() {
      return this.values.map((value, index) => ({
        id: index + 1,
        name: value,
      }));
    },
    selectedItem() {
      const id = this.values.indexOf(this.editedValue) + 1;
      return { id, name: this.editedValue };
    },
    isAttributeTypeCheckbox() {
      return this.attributeType === 'checkbox';
    },
    isAttributeTypeList() {
      return this.attributeType === 'list';
    },
    isAttributeTypeLink() {
      return this.attributeType === 'link';
    },
    isAttributeTypeDate() {
      return this.attributeType === 'date';
    },
    hasValue() {
      return this.value !== null && this.value !== '';
    },
    urlValue() {
      return isValidURL(this.value) ? this.value : '---';
    },
    hrefURL() {
      return isValidURL(this.value) ? this.value : '';
    },
    notAttributeTypeCheckboxAndList() {
      return !this.isAttributeTypeCheckbox && !this.isAttributeTypeList;
    },
    inputType() {
      return this.isAttributeTypeLink ? 'url' : this.attributeType;
    },
    shouldShowErrorMessage() {
      return this.v$.editedValue.$error;
    },
    errorMessage() {
      if (this.v$.editedValue.url?.$invalid) {
        return this.$t('CUSTOM_ATTRIBUTES.VALIDATIONS.INVALID_URL');
      }
      if (this.v$.editedValue.regexValidation?.$invalid) {
        return (
          this.regexCue ||
          this.$t('CUSTOM_ATTRIBUTES.VALIDATIONS.INVALID_INPUT')
        );
      }
      return this.$t('CUSTOM_ATTRIBUTES.VALIDATIONS.REQUIRED');
    },
  },
  watch: {
    value() {
      this.isEditing = false;
      this.editedValue = this.formattedValue;
    },
    contactId() {
      // Fix to solve validation not resetting when contactId changes in contact page
      this.v$.$reset();
    },
  },

  validations() {
    if (this.isAttributeTypeLink) {
      return {
        editedValue: { required, url },
      };
    }
    return {
      editedValue: {
        required,
        regexValidation: value => {
          if (!this.attributeRegex || !value) return true;
          try {
            return getRegexp(this.attributeRegex).test(value);
          } catch {
            return false;
          }
        },
      },
    };
  },
  mounted() {
    this.editedValue = this.formattedValue;
    emitter.on(BUS_EVENTS.FOCUS_CUSTOM_ATTRIBUTE, this.onFocusAttribute);
  },
  unmounted() {
    emitter.off(BUS_EVENTS.FOCUS_CUSTOM_ATTRIBUTE, this.onFocusAttribute);
  },
  methods: {
    onFocusAttribute(focusAttributeKey) {
      if (this.attributeKey === focusAttributeKey) {
        this.onEdit();
      }
    },
    focusInput() {
      if (this.$refs.inputfield) {
        this.$refs.inputfield.focus();
      }
    },
    onClickAway() {
      this.v$.$reset();
      this.isEditing = false;
    },
    onEdit() {
      this.isEditing = true;
      this.$nextTick(() => {
        this.focusInput();
      });
    },
    onUpdateListValue(value) {
      if (value) {
        this.editedValue = value.name;
        this.onUpdate();
      }
    },
    onUpdate() {
      const updatedValue =
        this.attributeType === 'date'
          ? parseISO(this.editedValue)
          : this.editedValue;
      this.v$.$touch();
      if (this.v$.$invalid) {
        return;
      }
      this.isEditing = false;
      this.$emit('update', this.attributeKey, updatedValue);
    },
    onDelete() {
      this.isEditing = false;
      this.v$.$reset();
      this.$emit('delete', this.attributeKey);
    },
    onCopy() {
      this.$emit('copy', this.value);
    },
  },
};
</script>

<template>
  <div class="flex items-start gap-2 px-3 py-1.5 group">
    <h4
      class="flex items-start w-[7.5rem] shrink-0 min-h-6 m-0 text-sm font-medium leading-6 error"
      :class="v$.editedValue.$error ? 'text-n-ruby-11' : 'text-n-slate-12'"
    >
      <span class="inline-flex gap-1.5 items-start min-w-0 break-words">
        {{ label }}
        <HelperTextPopup
          v-if="description"
          :message="description"
          class="mt-1.5"
        />
      </span>
    </h4>
    <div class="flex-1 min-w-0">
      <div v-if="isAttributeTypeCheckbox" class="flex items-center min-h-6">
        <input
          v-model="editedValue"
          class="!my-0 ltr:mr-2 ltr:ml-0 rtl:mr-0 rtl:ml-2"
          type="checkbox"
          @change="onUpdate"
        />
      </div>
      <div v-if="notAttributeTypeCheckboxAndList">
        <div v-if="isEditing" v-on-clickaway="onClickAway">
          <div class="flex items-center w-full">
            <input
              ref="inputfield"
              v-model="editedValue"
              :type="inputType"
              class="!h-8 ltr:!rounded-r-none rtl:!rounded-l-none !mb-0 !text-sm"
              autofocus="true"
              :class="{ error: v$.editedValue.$error }"
              @blur="v$.editedValue.$touch"
              @keyup.enter="onUpdate"
            />
            <div>
              <NextButton
                sm
                icon="i-lucide-check"
                class="ltr:rounded-l-none rtl:rounded-r-none h-[34px]"
                @click="onUpdate"
              />
            </div>
          </div>
          <span
            v-if="shouldShowErrorMessage"
            class="block w-full mt-1 text-sm font-normal text-n-ruby-11"
          >
            {{ errorMessage }}
          </span>
        </div>
        <div
          v-show="!isEditing"
          class="flex items-start min-h-6"
          :class="{ 'is-editable': showActions }"
        >
          <a
            v-if="isAttributeTypeLink"
            :href="hrefURL"
            target="_blank"
            rel="noopener noreferrer"
            class="group-hover:bg-n-slate-3 group-hover:dark:bg-n-solid-3 inline-block rounded-sm mb-0 break-all py-0.5 px-1 text-sm leading-5"
          >
            {{ urlValue }}
          </a>
          <p
            v-else
            class="group-hover:bg-n-slate-3 group-hover:dark:bg-n-solid-3 inline-block rounded-sm mb-0 break-all py-0.5 px-1 text-sm leading-5"
          >
            {{ displayValue }}
          </p>
          <div class="flex items-center gap-1 ml-1 rtl:mr-1 rtl:ml-0 shrink-0">
            <NextButton
              v-if="showActions && hasValue"
              v-tooltip="$t('CUSTOM_ATTRIBUTES.ACTIONS.COPY')"
              xs
              slate
              ghost
              icon="i-lucide-clipboard"
              class="hidden group-hover:flex flex-shrink-0"
              @click="onCopy"
            />
            <NextButton
              v-if="showActions"
              v-tooltip.right="$t('CUSTOM_ATTRIBUTES.ACTIONS.EDIT')"
              xs
              slate
              ghost
              icon="i-lucide-pen"
              class="hidden group-hover:flex flex-shrink-0"
              @click="onEdit"
            />
          </div>
        </div>
      </div>
      <div v-if="isAttributeTypeList">
        <MultiselectDropdown
          :options="listOptions"
          :selected-item="selectedItem"
          :has-thumbnail="false"
          :multiselector-placeholder="
            $t('CUSTOM_ATTRIBUTES.FORM.ATTRIBUTE_TYPE.LIST.PLACEHOLDER')
          "
          :no-search-result="
            $t('CUSTOM_ATTRIBUTES.FORM.ATTRIBUTE_TYPE.LIST.NO_RESULT')
          "
          :input-placeholder="
            $t(
              'CUSTOM_ATTRIBUTES.FORM.ATTRIBUTE_TYPE.LIST.SEARCH_INPUT_PLACEHOLDER'
            )
          "
          @select="onUpdateListValue"
        />
      </div>
    </div>
    <NextButton
      v-if="showActions && hasValue"
      v-tooltip.left="$t('CUSTOM_ATTRIBUTES.ACTIONS.DELETE')"
      slate
      xs
      ghost
      icon="i-lucide-trash-2"
      class="shrink-0 opacity-0 group-hover:opacity-100"
      @click="onDelete"
    />
  </div>
</template>

<style lang="scss" scoped>
:deep(.selector-wrap) {
  @apply m-0 top-1;

  .selector-name {
    @apply ml-0;
  }
}

:deep(.name) {
  @apply ml-0;
}
</style>
