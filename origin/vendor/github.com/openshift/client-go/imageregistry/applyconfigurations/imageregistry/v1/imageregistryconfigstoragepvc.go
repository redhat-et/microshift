// Code generated by applyconfiguration-gen. DO NOT EDIT.

package v1

// ImageRegistryConfigStoragePVCApplyConfiguration represents an declarative configuration of the ImageRegistryConfigStoragePVC type for use
// with apply.
type ImageRegistryConfigStoragePVCApplyConfiguration struct {
	Claim *string `json:"claim,omitempty"`
}

// ImageRegistryConfigStoragePVCApplyConfiguration constructs an declarative configuration of the ImageRegistryConfigStoragePVC type for use with
// apply.
func ImageRegistryConfigStoragePVC() *ImageRegistryConfigStoragePVCApplyConfiguration {
	return &ImageRegistryConfigStoragePVCApplyConfiguration{}
}

// WithClaim sets the Claim field in the declarative configuration to the given value
// and returns the receiver, so that objects can be built by chaining "With" function invocations.
// If called multiple times, the Claim field is set to the value of the last call.
func (b *ImageRegistryConfigStoragePVCApplyConfiguration) WithClaim(value string) *ImageRegistryConfigStoragePVCApplyConfiguration {
	b.Claim = &value
	return b
}
