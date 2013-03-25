//
//  ViewController.m
//  SamsungTVDemo
//
//  Created by Mike Godenzi on 25.03.13.
//  Copyright (c) 2013 Mike Godenzi. All rights reserved.
//
//  Permission is given to use this source code file, free of charge, in any
//  project, commercial or otherwise, entirely at your risk, with the condition
//  that any redistribution (in part or whole) of source code must retain
//  this copyright and permission notice. Attribution in compiled projects is
//  appreciated but not required.
//

#import "ViewController.h"
#import "SamsungTVManager.h"

#define N_KEYS 15

static NSString * KEYS[N_KEYS] = {
	@"KEY_0",
	@"KEY_1",
	@"KEY_2",
	@"KEY_3",
	@"KEY_4",
	@"KEY_5",
	@"KEY_6",
	@"KEY_7",
	@"KEY_8",
	@"KEY_9",
	@"KEY_VOLUP",
	@"KEY_VOLDOWN",
	@"KEY_MUTE",
	@"KEY_CHUP",
	@"KEY_CHDOWN",
};

@interface ViewController ()
@property (weak, nonatomic) IBOutlet UITextField *addressTextField;
@property (weak, nonatomic) IBOutlet UITextField *modelTextField;
@end

@implementation ViewController {
	BOOL _connected;
}

- (void)viewDidLoad {
    [super viewDidLoad];
	// Do any additional setup after loading the view, typically from a nib.
}


- (IBAction)buttonPressed:(UIButton *)sender {
	if (sender.tag < N_KEYS)
		[[SamsungTVManager sharedInstance] sendRemoteKey:KEYS[sender.tag]];
}

- (IBAction)connectButtonPressed:(UIButton *)sender {
	if (!_connected && [_addressTextField.text length] && [_modelTextField.text length]) {
		[[SamsungTVManager sharedInstance] connectToAddress:_addressTextField.text withTVModel:[_modelTextField.text uppercaseString] completion:^{
			_connected = YES;
			[sender setTitle:@"Disconnect" forState:UIControlStateNormal];
			[self enableButtons:YES];
		}];
	} else if (_connected) {
		[[SamsungTVManager sharedInstance] disconnect];
		_connected = NO;
		[sender setTitle:@"Connect" forState:UIControlStateNormal];
		[self enableButtons:NO];
	}
}

- (void)enableButtons:(BOOL)enable {
	for (NSInteger tag = 0; tag < N_KEYS; tag++) {
		UIButton * button = (UIButton *)[self.view viewWithTag:tag];
		button.enabled = enable;
	}
}

@end
