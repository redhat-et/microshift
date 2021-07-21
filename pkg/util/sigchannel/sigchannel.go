package sigchannel

// IsClosed tests whether a signalling channel has been closed.
// Note: Must only be used on broadcast signalling channels, i.e. channels
//       that only ever get closed, not sent any values.
func IsClosed(channel <-chan struct{}) bool {
	select {
	case <-channel:
		return true
	default:
		return false
	}
}

// AllClosed tests whether all signalling channels have been closed.
// Note: Must only be used on broadcast signalling channels, i.e. channels
//       that only ever get closed, not sent any values.
func AllClosed(channels []<-chan struct{}) bool {
	for _, channel := range channels {
		if !IsClosed(channel) {
			return false
		}
	}
	return true
}

// And returns a signalling channel that will be closed when all operand
// signalling channels have been closed.
// Note: As both And() and close() are async, it is possible and normal
//       for And() to return 'false' immediately after close() has been
//       called on its operands. Therefore, always use as blocking or in
//       a for-select-loop.
func And(channels []<-chan struct{}) <-chan struct{} {
	// terminate recursion
	switch len(channels) {
	case 0:
		andChannel := make(chan struct{})
		close(andChannel)
		return andChannel
	case 1:
		return channels[0]
	}

	andChannel := make(chan struct{})
	go func() {
		defer close(andChannel)

		// bipartition and recurse
		m := (len(channels) + 1) / 2
		a := And(channels[0:m])
		b := And(channels[m:])

		// wait for both partitions's signaling channels to close
		select {
		case <-a:
			<-b
		case <-b:
			<-a
		}
	}()
	return andChannel
}
