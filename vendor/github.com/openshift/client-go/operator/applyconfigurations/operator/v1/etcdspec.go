// Code generated by applyconfiguration-gen. DO NOT EDIT.

package v1

import (
	operatorv1 "github.com/openshift/api/operator/v1"
	runtime "k8s.io/apimachinery/pkg/runtime"
)

// EtcdSpecApplyConfiguration represents an declarative configuration of the EtcdSpec type for use
// with apply.
type EtcdSpecApplyConfiguration struct {
	StaticPodOperatorSpecApplyConfiguration `json:",inline"`
	HardwareSpeed                           *operatorv1.ControlPlaneHardwareSpeed `json:"controlPlaneHardwareSpeed,omitempty"`
}

// EtcdSpecApplyConfiguration constructs an declarative configuration of the EtcdSpec type for use with
// apply.
func EtcdSpec() *EtcdSpecApplyConfiguration {
	return &EtcdSpecApplyConfiguration{}
}

// WithManagementState sets the ManagementState field in the declarative configuration to the given value
// and returns the receiver, so that objects can be built by chaining "With" function invocations.
// If called multiple times, the ManagementState field is set to the value of the last call.
func (b *EtcdSpecApplyConfiguration) WithManagementState(value operatorv1.ManagementState) *EtcdSpecApplyConfiguration {
	b.ManagementState = &value
	return b
}

// WithLogLevel sets the LogLevel field in the declarative configuration to the given value
// and returns the receiver, so that objects can be built by chaining "With" function invocations.
// If called multiple times, the LogLevel field is set to the value of the last call.
func (b *EtcdSpecApplyConfiguration) WithLogLevel(value operatorv1.LogLevel) *EtcdSpecApplyConfiguration {
	b.LogLevel = &value
	return b
}

// WithOperatorLogLevel sets the OperatorLogLevel field in the declarative configuration to the given value
// and returns the receiver, so that objects can be built by chaining "With" function invocations.
// If called multiple times, the OperatorLogLevel field is set to the value of the last call.
func (b *EtcdSpecApplyConfiguration) WithOperatorLogLevel(value operatorv1.LogLevel) *EtcdSpecApplyConfiguration {
	b.OperatorLogLevel = &value
	return b
}

// WithUnsupportedConfigOverrides sets the UnsupportedConfigOverrides field in the declarative configuration to the given value
// and returns the receiver, so that objects can be built by chaining "With" function invocations.
// If called multiple times, the UnsupportedConfigOverrides field is set to the value of the last call.
func (b *EtcdSpecApplyConfiguration) WithUnsupportedConfigOverrides(value runtime.RawExtension) *EtcdSpecApplyConfiguration {
	b.UnsupportedConfigOverrides = &value
	return b
}

// WithObservedConfig sets the ObservedConfig field in the declarative configuration to the given value
// and returns the receiver, so that objects can be built by chaining "With" function invocations.
// If called multiple times, the ObservedConfig field is set to the value of the last call.
func (b *EtcdSpecApplyConfiguration) WithObservedConfig(value runtime.RawExtension) *EtcdSpecApplyConfiguration {
	b.ObservedConfig = &value
	return b
}

// WithForceRedeploymentReason sets the ForceRedeploymentReason field in the declarative configuration to the given value
// and returns the receiver, so that objects can be built by chaining "With" function invocations.
// If called multiple times, the ForceRedeploymentReason field is set to the value of the last call.
func (b *EtcdSpecApplyConfiguration) WithForceRedeploymentReason(value string) *EtcdSpecApplyConfiguration {
	b.ForceRedeploymentReason = &value
	return b
}

// WithFailedRevisionLimit sets the FailedRevisionLimit field in the declarative configuration to the given value
// and returns the receiver, so that objects can be built by chaining "With" function invocations.
// If called multiple times, the FailedRevisionLimit field is set to the value of the last call.
func (b *EtcdSpecApplyConfiguration) WithFailedRevisionLimit(value int32) *EtcdSpecApplyConfiguration {
	b.FailedRevisionLimit = &value
	return b
}

// WithSucceededRevisionLimit sets the SucceededRevisionLimit field in the declarative configuration to the given value
// and returns the receiver, so that objects can be built by chaining "With" function invocations.
// If called multiple times, the SucceededRevisionLimit field is set to the value of the last call.
func (b *EtcdSpecApplyConfiguration) WithSucceededRevisionLimit(value int32) *EtcdSpecApplyConfiguration {
	b.SucceededRevisionLimit = &value
	return b
}

// WithHardwareSpeed sets the HardwareSpeed field in the declarative configuration to the given value
// and returns the receiver, so that objects can be built by chaining "With" function invocations.
// If called multiple times, the HardwareSpeed field is set to the value of the last call.
func (b *EtcdSpecApplyConfiguration) WithHardwareSpeed(value operatorv1.ControlPlaneHardwareSpeed) *EtcdSpecApplyConfiguration {
	b.HardwareSpeed = &value
	return b
}
